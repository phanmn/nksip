%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc Authentication management module.

-module(nksip_auth).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([authorize_data/2, realms/1, make_ha1/3]).
-export([make_request/3, make_response/2, get_authentication/2]).

% -include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-define(RESP_WWW, (<<"www-authenticate">>)).
-define(RESP_PROXY, (<<"proxy-authenticate">>)).
-define(REQ_WWW,  (<<"authorization">>)).
-define(REQ_PROXY,  (<<"proxy-authorization">>)).


%% ===================================================================
%% Public
%% ===================================================================


%%----------------------------------------------------------------
%% @doc Extracts all the realms present in <i>WWW-Authenticate</i> or
%% <i>Proxy-Authenticate</i> headers from a response.
%% @end
%%----------------------------------------------------------------
-spec realms( SipMessageOrHandle ) -> RealmsList when
        SipMessageOrHandle  :: nksip:response() 
            | nksip:handle(),
        RealmsList          :: [ Realm ],
        Realm               :: binary().

realms(#sipmsg{headers=Headers}) ->
    get_realms(Headers, []);

realms(RespId) ->
    Hd1 = case nksip_response:header(RespId, ?RESP_WWW) of
        {ok, WWW} when is_list(WWW) ->
            [{?RESP_WWW, Data} || Data <- WWW];
        _ ->
            []
    end,
    Hd2 = case nksip_response:header(RespId, ?RESP_PROXY) of
        {ok, Proxy} when is_list(Proxy) ->
            [{?RESP_PROXY, Data} || Data <- Proxy];
        _ ->
            []
    end,
    get_realms(Hd1++Hd2, []).


%% @private
get_realms([{Name, Value}|Rest], Acc) ->
    if
        Name==?RESP_WWW; Name==?RESP_PROXY ->
            case parse_header(Value) of
                {error, _} ->
                    get_realms(Rest, Acc);
                AuthData ->
                    get_realms(Rest, [nklib_util:get_value(realm, AuthData)|Acc])
            end;
        true ->
            get_realms(Rest, Acc)
    end;
get_realms([], Acc) ->
    lists:usort(Acc).


%%----------------------------------------------------------------
%% @doc Generates a password hash to use in NkSIP authentication.
%% In order to avoid storing the user's passwords in clear text, you can generate 
%% a `hash' (fom `User', `Pass' and `Realm') and store and use it in
%% {@link nksip_sipapp:get_user_pass/3} instead of the real password.
%% @end
%%----------------------------------------------------------------
-spec make_ha1( User, Password, Realm ) -> Result when 
        User    :: binary()|string(),
        Password    :: binary()|string(), 
        Realm       :: binary()|string(),
        Result      :: binary().

make_ha1(User, Pass, Realm) ->
    % <<"HA1!">> is a custom header to be detected as a ha1 hash
    <<"HA1!", (md5(list_to_binary([User, $:, Realm, $:, Pass])))/binary>>.


%%----------------------------------------------------------------
%% @doc Adds an <i>Authorization</i> or <i>Proxy-Authorization</i> header 
%% for a request after receiving a 401 or 407 response.
%% CSeq must be updated after calling this function.
%%
%% Recognized options are `sip_pass', `user', `cnonce' and `nc'.
%% @end
%%----------------------------------------------------------------
-spec make_request( Request, Response, OptionsList ) -> Result when 
        Request     :: nksip:request(), 
        Response    :: nksip:response(),
        OptionsList :: nksip:optslist(),
        Result      :: {ok, Request} 
            | {error, Error},
        Error       :: invalid_auth_header | unknown_nonce | no_pass.

make_request(Req, #sipmsg{headers=RespHeaders}, Opts) ->
    #sipmsg{
        class = {req, Method},
        ruri = RUri,
        from = {#uri{user=User}, _},
        headers = ReqHeaders
    } = Req,
    try
        ReqAuthHeaders = nklib_util:extract(ReqHeaders, [?REQ_WWW, ?REQ_PROXY]),
        ReqNOnces = [
            case parse_header(ReqAuthHeader) of
                {error, _} ->
                    throw(invalid_auth_header);
                ParsedReqHeader ->
                    nklib_util:get_value(nonce, ParsedReqHeader)
            end 
            || {_, ReqAuthHeader} <- ReqAuthHeaders
        ],
        RespAuthHeaders = nklib_util:extract(RespHeaders, [?RESP_WWW, ?RESP_PROXY]),
        {RespName, RespData}= case RespAuthHeaders of
            [{RespName0, RespData0}] ->
                {RespName0, RespData0};
            _ ->
                throw(invalid_auth_header)
        end,
        AuthHeaderData = case parse_header(RespData) of
            {error, _} ->
                throw(invalid_auth_header);
            AuthHeaderData0 ->
                AuthHeaderData0
        end,
        RespNOnce = nklib_util:get_value(nonce, AuthHeaderData),
        case lists:member(RespNOnce, ReqNOnces) of
            true ->
                throw(unknown_nonce);
            false ->
                ok
        end,
        ReqOpts = case nklib_util:get_value(sip_pass, Opts) of
            undefined ->
                throw(no_pass);
            Passes ->
                [
                    {method, Method}, 
                    {ruri, RUri}, 
                    {user, nklib_util:get_binary(user, Opts, User)}, 
                    {sip_pass, Passes} 
                    | Opts
                ]
        end,
        case make_auth_request(AuthHeaderData, ReqOpts) of
            error ->
                throw(invalid_auth_header);
            {ok, ReqData} ->
                ReqName = case RespName of
                    ?RESP_WWW ->
                        ?REQ_WWW;
                    ?RESP_PROXY ->
                        ?REQ_PROXY
                end,
                ReqHeaders1 = [{ReqName, ReqData}|ReqHeaders],
                {ok, Req#sipmsg{headers=ReqHeaders1}}
        end
    catch
        throw:Error ->
            {error, Error}
    end.


%%----------------------------------------------------------------
%% @doc Generates a <i>WWW-Authenticate</i> or <i>Proxy-Authenticate</i> header
%% in response to a request.
%% Use this function to answer to a request with a 401 or 407 response.
%%
%% A new `nonce' will be generated to be used by the client in its response, 
%% but will expire after the time configured in global parameter `nonce_timeout'.
%%
%% @end
%%----------------------------------------------------------------
-spec make_response( Realm, Request ) -> Result when
        Realm       :: binary(), 
        Request     :: nksip:request(),
        Result      :: binary().

make_response(Realm, Req) ->
    #sipmsg{
        srv_id = SrvId,
        call_id = CallId,
        nkport = NkPort
    } = Req,
    {ok, {_, _, Ip, _Port}} = nkpacket:get_remote(NkPort),
    Nonce = nklib_util:luid(),
    #config{nonce_timeout=Timeout} = nksip_config:srv_config(SrvId),
    % We don't put the port any more, since in an deep chain of proxies,
    % we can start with UDP and switch to TCP in the middle of the process
    %Term = {Ip, Port},
    Term = Ip,
    put_nonce(SrvId, CallId, Nonce, Term, Timeout),
    Opaque = nklib_util:hash(SrvId),
    list_to_binary([
        "Digest realm=\"", Realm, "\", nonce=\"", Nonce, "\", "
        "algorithm=MD5, qop=\"auth\", opaque=\"", Opaque, "\""
    ]).


%%----------------------------------------------------------------
%% @doc Extracts digest authentication information from a incoming request.
%% The response can include:
%% <ul>
%%    <li>`{{digest, Realm}, true}': there is at least one valid user authenticated
%%        with this `Realm'.</li>
%%    <li>`{{digest, Realm}, invalid}': there is at least one user offering
%%        an invalid authentication header for this `Realm'</li>
%%    <li>`{{digest, Realm}, false}': there is at least one user offering 
%%        an authentication header for this `Realm', but all of them have
%%        failed the authentication.</li>
%% </ul>
%%
%% @end
%%----------------------------------------------------------------
-spec authorize_data( Request, Call ) -> AuthorizedList when 
        Request         :: nksip:request(), 
        Call            :: nksip_call:call(),
        AuthorizedList  :: [ Authorized ],
        Authorized      :: {{digest, Realm}, true }
            | {{digest, Realm}, invalid }
            | {{digest, Realm}, false},
        Realm           :: binary().

authorize_data(Req, #call{srv_id=SrvId}=Call) ->
    PassFun = fun(User, Realm) ->
        Args = [User, Realm, Req, Call],
        Reply = case nksip_util:user_callback(SrvId, sip_get_user_pass, Args) of
            {ok, Reply0} ->
                Reply0;
            error ->
                false
        end,
        ?CALL_DEBUG("UAS calling get_user_pass(~p, ~p, Req, Call): ~p",
                    [User, Realm, Reply]),
        Reply
    end,
    get_authentication(Req, PassFun).


%% ===================================================================
%% Private
%% ===================================================================


%%----------------------------------------------------------------
%% @doc Extracts digest authentication information from a incoming request.
%%
%% `Fun' will be called when a password for a pair user, realm is needed.
%% It can return `true' (accepts the request with any password), `false' 
%% (doesn't accept the request) or a `binary()' pasword or hash.
%% @see authorize_data/2
%% @private
%% @end
%%----------------------------------------------------------------
-spec get_authentication( Request, Function ) -> AuthorizedList when
        Request     :: nksip:request(),
        Function    :: function(), 
        AuthorizedList  :: [ Authorized ],
        Authorized      :: {{digest, Realm}, true | invalid | false},
        Realm           :: binary().

get_authentication(Req, PassFun) ->
    Fun = fun({Res, _User, Realm}, Acc) ->
        case lists:keyfind(Realm, 1, Acc) of
            false ->
                [{Realm, Res}|Acc];
            {Realm, true} ->
                Acc;
            {Realm, _} when Res == true ->
                nklib_util:store_value(Realm, Res, Acc);
            {Realm, invalid} ->
                Acc;
            {Realm, _} when Res == invalid ->
                nklib_util:store_value(Realm, Res, Acc);
            {Realm, false} ->
                Acc
        end
    end,
    [{{digest, Realm}, Res} || 
        {Realm, Res} <- lists:foldl(Fun, [], check_digest(Req, PassFun))].


%%----------------------------------------------------------------
%% @doc Finds auth headers in request, and for each one extracts user and 
%% realm, calling `get_user_pass/3' callback to check if it is correct.
%% @private
%% @end
%%----------------------------------------------------------------
-spec check_digest( Request, Function ) -> ResultList when 
        Request     :: nksip:request(),
        Function    :: function(), 
        ResultList  :: [ Result ],
        Result      ::  {true | invalid | false, User, Realm},
        User        :: binary(),
        Realm       :: binary().

check_digest(#sipmsg{headers=Headers}=Req, Fun) ->
    check_digest(Headers, Req, Fun, []).


%% @private
check_digest([], _Req, _Fun, Acc) ->
    Acc;

check_digest([{Name, Data}|Rest], Req, Fun, Acc) 
                when Name==?REQ_WWW; Name==?REQ_PROXY ->
    case parse_header(Data) of
        {error, _} ->
            check_digest(Rest, Req, Fun, Acc);
        AuthData ->
            Resp = nklib_util:get_value(response, AuthData),
            User = nklib_util:get_binary(username, AuthData),
            Realm = nklib_util:get_binary(realm, AuthData),
            Result = case Fun(User, Realm) of
                true ->
                    true;
                false ->
                    false;
                Pass ->
                    check_auth_header(AuthData, Resp, User, Realm, Pass, Req)
            end,
            check_digest(Rest, Req, Fun, [{Result, User, Realm}|Acc])
    end;
    
check_digest([_|Rest], Req, Fun, Acc) ->
    check_digest(Rest, Req, Fun, Acc).


%%----------------------------------------------------------------
%% @doc Generates a Authorization or Proxy-Authorization header
%% @private
%% @end
%%----------------------------------------------------------------
-spec make_auth_request( AuthHeaderData, UserOpts ) -> Result when 
            AuthHeaderData  :: nksip:optslist(),
            UserOpts        :: nksip:optslist(),
            Result          :: {ok, binary()} 
                | error.

make_auth_request(AuthHeaderData, UserOpts) ->
    QOP = nklib_util:get_value(qop, AuthHeaderData, []),
    Algorithm = nklib_util:get_value(algorithm, AuthHeaderData, 'MD5'),
    case Algorithm=='MD5' andalso (QOP==[] orelse lists:member(auth, QOP)) of
        true ->
            CNonce = case nklib_util:get_binary(cnonce, UserOpts) of
                <<>> ->
                    nklib_util:luid();
                CNonce0 ->
                    CNonce0
            end,
            Nonce = nklib_util:get_binary(nonce, AuthHeaderData, <<>>),  
            Nc = nklib_util:msg("~8.16.0B", [nklib_util:get_integer(nc, UserOpts, 1)]),
            Realm = nklib_util:get_binary(realm, AuthHeaderData, <<>>),
            Passes = nklib_util:get_value(sip_pass, UserOpts, []),
            Pass = case nklib_util:get_value(Realm, Passes) of
                undefined ->
                    nklib_util:get_value(<<>>, Passes, <<>>);
                RealmPass ->
                    RealmPass
            end,
            User = nklib_util:get_binary(user, UserOpts),
            HA1 = case Pass of
                <<"HA1!", HA10/binary>> ->
                    HA10; %_Pass = <<"hash">>;
                _ ->
                    <<"HA1!", HA10/binary>> = make_ha1(User, Pass, Realm),
                    HA10
            end,
            Uri = nklib_unparse:uri3(nklib_util:get_value(ruri, UserOpts)),
            Method1 = case nklib_util:get_value(method, UserOpts) of
                'ACK' ->
                    'INVITE';
                Method ->
                    Method
            end,
            Resp = make_auth_response(QOP, Method1, Uri, HA1, Nonce, CNonce, Nc),
            % ?P("AUTH REQUEST: ~p, ~p, ~p: ~p", [User, _Pass, Realm, Resp]),
            % ?P("AUTH REQUEST: ~p, ~p, ~p, ~p, ~p, ~p, ~p", 
            %               [QOP,  Method1, Uri, HA1, Nonce, CNonce, Nc]),
            Raw = [
                "Digest username=\"", User, "\", realm=\"", Realm, 
                "\", nonce=\"", Nonce, "\", uri=\"", Uri, "\", response=\"", Resp, 
                "\", algorithm=MD5",
                case QOP of
                    [] ->
                        [];
                    _ ->
                        [", qop=auth, cnonce=\"", CNonce, "\", nc=", Nc]
                end,
                case nklib_util:get_value(opaque, AuthHeaderData) of
                    undefined ->
                        [];
                    Opaque ->
                        [", opaque=\"", Opaque, "\""]
                end
            ],
            {ok, list_to_binary(Raw)};
        false ->
            error
    end.


%%----------------------------------------------------------------
%% @doc Check Auth Header
%% @private
%% @end
%%----------------------------------------------------------------
-spec check_auth_header(AuthHeader, Response, User, Realm, Password, Request ) -> Result when
        AuthHeader      :: nksip:optslist(), 
        Response        :: binary(), 
        User            :: binary(), 
        Realm           :: binary(), 
        Password        :: binary(), 
        Request         :: nksip:request(),
        Result          :: true | invalid | false.

check_auth_header(AuthHeader, Resp, User, Realm, Pass, Req) ->
    #sipmsg{
        srv_id = SrvId,
        class = {req, Method},
        call_id = CallId,
        nkport = NkPort
    } = Req,
    {ok, {_, _, Ip, Port}} = nkpacket:get_remote(NkPort),
    case
        nklib_util:get_value(scheme, AuthHeader) /= digest orelse
        nklib_util:get_value(qop, AuthHeader) /= [auth] orelse
        nklib_util:get_value(algorithm, AuthHeader, 'MD5') /= 'MD5'
    of
        true ->
            ?N("received invalid parameters in Authorization Header: ~p (~s)",
                    [AuthHeader, CallId]),
            invalid;
        false ->
            % Should we check the uri in the authdata matches the ruri of the request?
            Uri = nklib_util:get_value(uri, AuthHeader),
            Nonce = nklib_util:get_value(nonce, AuthHeader),
            TestTerm = get_nonce(SrvId, CallId, Nonce),
            if
                TestTerm==not_found ->
                    Opaque = nklib_util:get_value(opaque, AuthHeader),
                    case nklib_util:hash(SrvId) of
                        Opaque ->
                            ?CALL_LOG(notice, "received invalid nonce", []);
                        _ ->
                            ok
                    end,
                    invalid;
                Method=='ACK' orelse TestTerm=={Ip, Port} orelse TestTerm==Ip ->
                    CNonce = nklib_util:get_value(cnonce, AuthHeader),
                    Nc = nklib_util:get_value(nc, AuthHeader),
                    HA1 = case nklib_util:to_binary(Pass) of
                        <<"HA1!", HA10/binary>> ->
                            HA10;
                        _ ->
                            <<"HA1!", HA10/binary>> = make_ha1(User, Pass, Realm),
                            HA10
                    end,
                    QOP = [auth],
                    Method1 = case Method of
                        'ACK' ->
                            'INVITE';
                        _ ->
                            Method
                    end,
                    ValidResp = make_auth_response(QOP, Method1, Uri, HA1, 
                                                        Nonce, CNonce, Nc),
                    % ?P("AUTH RESP: ~p, ~p, ~p: ~p vs ~p", 
                    %       [User, Pass, Realm, Resp, ValidResp]),
                    % ?P("AUTH RESP: ~p, ~p, ~p, ~p, ~p, ~p, ~p", 
                    %       [QOP, Method1, Uri, HA1, Nonce, CNonce, Nc]),
                    Resp == ValidResp;
                true ->
                    ?CALL_LOG(warning, "received nonce (~p) from different Ip or Port", [SrvId]),
                    %?CALL_LOG(warning, "M: ~p, F:~p, IP:~p", [Method, Found, {Ip, Port}]),
                    false
            end
    end.


%% ===================================================================
%% Internal
%% ===================================================================

% %% @private
% get_passes([], Acc) ->
%     lists:reverse(Acc);

% get_passes([Opt|Rest], Acc) ->
%     Acc1 = case Opt of
%         {passes, PassList} -> PassList++Acc;
%         {pass, {P, R}} -> [{nklib_util:to_binary(P), nklib_util:to_binary(R)}|Acc];
%         {pass, P} -> [{nklib_util:to_binary(P), <<>>}|Acc];
%         _ -> Acc
%     end,
%     get_passes(Rest, Acc1).

%%----------------------------------------------------------------
%% @doc Generates a standard SIP Digest Response
%% @private
%% @end
%%----------------------------------------------------------------
-spec make_auth_response( QOP, Method, BinUri, HA1Bin, Nonce, CNonce, Nc ) -> Result when 
            QOP             :: [ atom() ], 
            Method          :: nksip:method(), 
            BinUri          :: binary(), 
            HA1Bin          :: binary(), 
            Nonce           :: binary(), 
            CNonce          :: binary(), 
            Nc              :: binary(),
            Result          :: binary().

make_auth_response(QOP, Method, BinUri, HA1bin, Nonce, CNonce, Nc) ->
    HA1 = nklib_util:hex(HA1bin),
    HA2_base = <<(nklib_util:to_binary(Method))/binary, ":", BinUri/binary>>,
    HA2 = nklib_util:hex(md5(HA2_base)),
    case QOP of
        [] ->
            nklib_util:hex(md5(list_to_binary([HA1, $:, Nonce, $:, HA2])));
        _ ->    
            case lists:member(auth, QOP) of
                true ->
                    nklib_util:hex(md5(list_to_binary(
                        [HA1, $:, Nonce, $:, Nc, $:, CNonce, ":auth:", HA2])));
                _ ->
                    <<>>
            end 
    end.


%% @private
md5(Term) -> crypto:hash(md5, Term).


% %% @private Extracts password from user options.
% %% The first matching realm is used, otherwise first password without realm
% -spec get_pass([{binary(), binary()}], binary(), binary()) ->
%     Pass::binary().

% get_pass([], _Realm, FirstPass) ->
%     FirstPass;
% get_pass([{<<>>, FirstPass}|Rest], Realm, <<>>) ->
%     get_pass(Rest, Realm, FirstPass);
% get_pass([{Realm, Pass}|_], Realm, _FirstPass) ->
%     Pass;
% get_pass([_|Rest], Realm, FirstPass) ->
%     get_pass(Rest, Realm, FirstPass).


%% @private
get_nonce(SrvId, CallId, Nonce) ->
    nklib_store:get({nksip_auth_nonce, SrvId, CallId, Nonce}).

%% @private
put_nonce(SrvId, CallId, Nonce, Term, Timeout) ->
    nklib_store:put({nksip_auth_nonce, SrvId, CallId, Nonce}, Term,
                    [{ttl, Timeout}]).


%%----------------------------------------------------------------
%% @doc Parsed Header 
%% @private
%% @end
%%----------------------------------------------------------------
-spec parse_header( StringOrBinary ) -> Results when 
            StringOrBinary  :: string() 
                | binary(),
            Results         :: nksip:optslist() 
                | {error, term()}.

parse_header(Bin) when is_binary(Bin) ->
    parse_header(binary_to_list(Bin));

parse_header(List) when is_list(List) ->
    case parse_header_scheme(strip(List), []) of
        {error, Error} ->
            {error, Error};
        Opts ->
            lists:reverse(Opts)
    end.


%% @private 
parse_header_scheme([], _Acc) ->
    {error, ?LINE};

parse_header_scheme([Ch|Rest], Acc) when Ch==32; Ch==9; Ch==13 ->
    case Acc of
        [] ->
            error;
        _ ->
            Scheme = case string:to_lower(lists:reverse(Acc)) of
                "digest" ->
                    digest;
                "basic" ->
                    basic;
                Other ->
                    list_to_binary(Other)
            end,
            parse_header_key(strip(Rest), [], [{scheme, Scheme}])
    end;

parse_header_scheme([Ch|Rest], Acc) ->
    parse_header_scheme(Rest, [Ch|Acc]).


%% @private
parse_header_key([], _Acc, _Data) ->
    {error, ?LINE};

parse_header_key([$=|Rest], Acc, Data) ->
    Key = lists:reverse(Acc),
    parse_header_value(strip(Rest), Key, [], false, Data);

parse_header_key([Ch|Rest], Acc, Data) when Ch==32; Ch==9; Ch==13 ->
    case strip(Rest) of
        [$=|_]=Rest1 ->
            parse_header_key(Rest1, Acc, Data);
        _ ->
            {error, ?LINE}
    end;

parse_header_key([Ch|Rest], Acc, Data) ->
    parse_header_key(Rest, [Ch|Acc], Data).


%% @private
parse_header_value([], Key, Acc, Quoted, Data) ->
    case Acc==[] orelse Quoted of
        true ->
            {error, ?LINE};
        false ->
            [parse_header_value_check(Key, lists:reverse(Acc))|Data]
    end;

parse_header_value([92, $"|Rest], Key, Acc, true, Data) ->
    parse_header_value(Rest, Key, [$", 92|Acc], true, Data);

parse_header_value([$"|Rest], Key, Acc, Quoted, Data) ->
    parse_header_value(Rest, Key, [$"|Acc], not Quoted, Data);

parse_header_value([$,|Rest], Key, Acc, false, Data) ->
    case Acc of
        [] ->
            {error, ?LINE};
        _ ->
            Data1 = [parse_header_value_check(Key, lists:reverse(Acc))|Data],
            parse_header_key(strip(Rest), [], Data1)
    end;

parse_header_value([Ch|Rest], Key, Acc, false, Data) when Ch==32; Ch==9; Ch==13 ->
    case strip(Rest) of
        [] ->
            parse_header_value([], Key, Acc, false, Data);
        [$,|_]=Rest1 ->
            parse_header_value(Rest1, Key, Acc, false, Data);
        R ->
            {error, ?LINE, R}
    end;

parse_header_value([Ch|Rest], Key, Acc, Quoted, Data) ->
    parse_header_value(Rest, Key, [Ch|Acc], Quoted, Data).


%% @private
parse_header_value_check(Key, Val) ->
    Val1 = string:strip(Val, both, $"),
    case string:to_lower(Key) of
        "realm" ->
            {realm, list_to_binary(string:to_lower(Val1))};
        "nonce" ->
            {nonce, list_to_binary(Val1)};
        "opaque" ->
            {opaque, list_to_binary(Val1)};
        "username" ->
            {username, list_to_binary(Val1)};
        "uri" ->
            {uri, list_to_binary(Val1)};
        "response" ->
            {response, list_to_binary(Val1)};
        "cnonce" ->
            {cnonce, list_to_binary(Val1)};
        "nc" ->
            {nc, list_to_binary(Val1)};
        "algorithm" ->
            {algorithm, 
                case string:to_lower(Val1) of
                    "md5" ->
                        'MD5';
                    A0 ->
                        list_to_binary(A0)
                end};
        "qop" ->
            QOP = [
                case string:to_lower(QOPToken) of
                    "auth" ->
                        auth;
                    "auth-int" ->
                        'auth-int';
                    _ ->
                        list_to_binary(QOPToken)
                end
                || QOPToken <- string:tokens(Val1, " ,")
            ],
            {qop, QOP};
        Other ->
            {list_to_binary(Other), list_to_binary(Val1)}
    end.


%% @private
strip([32|Rest]) -> strip(Rest);
strip([13|Rest]) -> strip(Rest);
strip([10|Rest]) -> strip(Rest);
strip([9|Rest]) -> strip(Rest);
strip(Rest) -> Rest.



%% ===================================================================
%% EUnit tests
%% ===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ha1_test() ->
    HA1 = <<132,147,251,197,59,165,130,251,76,4,76,69,107,220,64,235>>,
    ?assertMatch(<<"HA1!", HA1/binary>>, make_ha1("user", "pass", "realm")),
    ?assertMatch(
        <<"194370e184088fb011b140d770936009">>,
        make_auth_response([], 'INVITE', <<"test@test.com">>, HA1, 
                            <<"gfedcba">>, <<"abcdefg">>, 1)),
    ?assertMatch(
        <<"788a70e3b5d371dc5f9dee5e59bb80cd">>,
        make_auth_response([other, auth], 'INVITE', <<"test@test.com">>, HA1, 
                            <<"gfedcba">>, <<"abcdefg">>, 1)),
    ?assertMatch(<<>>, make_auth_response([other], 'INVITE', <<"any">>, HA1, <<"any">>,
                 <<"any">>, 1)),
    [
        {scheme,digest},
        {realm,<<"av">>},
        {<<"b">>, <<"1, 2\\\"bc\\\" ">>},
        {qop,[auth,'auth-int',<<"other">>]}
    ] = 
        parse_header("   Digest   realm   =   AV,b=\"1, 2\\\"bc\\\" \", "
                      "qop = \"auth,  auth-int,other\"").
-endif.



