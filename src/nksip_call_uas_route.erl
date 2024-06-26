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

%% @private Call UAS Management: Request Processing
-module(nksip_call_uas_route).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([launch/2]).

-import(nksip_call_lib, [update/2]).

% -include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("nkserver/include/nkserver.hrl").

%% ===================================================================
%% Route processing
%% ===================================================================

%% @private 
-spec launch(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

launch(UAS, Call) ->
    send_100(UAS, Call).


%% @private 
-spec send_100(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

send_100(UAS, #call{srv_id=SrvId}=Call) ->
    #trans{method=Method, request=Req} = UAS,
    Config = nksip_config:srv_config(SrvId),
    case Method=='INVITE' andalso (not Config#config.no_100) of
        true ->
            {Resp, SendOpts} = nksip_reply:reply(Req, 100),
            case nksip_call_uas_transp:send_response(Resp, SendOpts) of
                {ok, _} ->
                    check_cancel(UAS, Call);
                {error, _} ->
                    ?CALL_LOG(notice, "UAS ~p ~p could not send '100' response", [UAS#trans.id, Method]),
                    nksip_call_uas:do_reply(service_unavailable, UAS, Call)
            end;
        false ->
            check_cancel(UAS, Call)
    end.
        

%% @private
-spec check_cancel(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

check_cancel(UAS, #call{srv_id=SrvId}=Call) ->
    case is_cancel(UAS, Call) of
        {true, #trans{status=invite_proceeding, from=From}=InvUAS} ->
            ?CALL_DEBUG("UAS ~p matched 'CANCEL' as ~p", [UAS#trans.id, InvUAS#trans.id]),
            Call1 = nksip_call_uas:do_reply(ok, UAS, Call), 
            Args = [InvUAS#trans.request, UAS#trans.request, Call1],
            nksip_util:user_callback(SrvId, sip_cancel, Args),
            case From of
                {fork, ForkId} ->
                    % We do not cancel our UAS request, we send it to the fork
                    % Proxied remotes should send the 487 (ot not)
                    nksip_call_fork:cancel(ForkId, Call1);
                _ ->  
                    InvUAS1 = InvUAS#trans{cancel=cancelled},
                    Call2 = update(InvUAS1, Call1),
                    nksip_call_uas:do_reply(request_terminated, InvUAS1, Call2)
            end;
        {true, _} ->
            nksip_call_uas:do_reply(no_transaction, UAS, Call);
        false ->
            authorize_launch(UAS, Call)
    end.


%% @private Finds the INVITE transaction belonging to a CANCEL transaction
-spec is_cancel(nksip_call:trans(), nksip_call:call()) ->
    {true, nksip_call:trans()} | false.

is_cancel(#trans{method='CANCEL', request=CancelReq}, #call{trans=Trans}) ->
    TransReq = CancelReq#sipmsg{class={req, 'INVITE'}},
    ReqTransId = nksip_call_lib:uas_transaction_id(TransReq),
    case lists:keyfind(ReqTransId, #trans.trans_id, Trans) of
        #trans{class=uas, request=#sipmsg{}=InvReq} = InvUAS ->
            #sipmsg{nkport=CancelNkPort} = CancelReq,
            {ok, {_, _, CancelIp, CancelPort}} = nkpacket:get_remote(CancelNkPort),
            #sipmsg{nkport=InvNkPort} = InvReq,
            {ok, {_, _, InvIp, InvPort}} = nkpacket:get_remote(InvNkPort),
            if
                CancelIp==InvIp, CancelPort==InvPort ->
                    {true, InvUAS};
                true ->
                    ?CALL_LOG(notice, "UAS ~p rejecting CANCEL because it came from ~p:~p, "
                                 "INVITE came from ~p:~p", 
                                 [InvUAS#trans.id, CancelIp, CancelPort, InvIp, InvPort]),
                    false
            end;
        _ ->
            ?CALL_DEBUG("received CANCEL for unknown transaction", []),
            false
    end;

is_cancel(_, _) ->
    false.


%% @private
-spec authorize_launch(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

authorize_launch(#trans{request=Req}=UAS, #call{srv_id=SrvId}=Call) ->
    % In case app has not implemented sip_authorize, we don't spend time
    % finding authentication info
    case catch ?CALL_SRV(SrvId, sip_authorize, [[], Req, Call]) of
        ok ->
            authorize_reply(ok, UAS, Call);
        _ ->
            {ok, AuthData} =  ?CALL_SRV(SrvId, nksip_authorize_data, [[], UAS, Call]),
            Args = [AuthData, Req, Call],
            case nksip_util:user_callback(SrvId, sip_authorize, Args) of
                {ok, Reply} ->
                    authorize_reply(Reply, UAS, Call);
                error ->
                    nksip_call_uas:do_reply({internal_error, "Service Error"}, UAS, Call)
            end
    end.


%% @private
-spec authorize_reply(term(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

authorize_reply(Reply, UAS, Call) ->
    #trans{request=Req} = UAS,
    #sipmsg{dialog_id=DialogId, to={_, ToTag}} = Req,
    ?CALL_DEBUG("UAS ~p ~p authorize reply: ~p", [UAS#trans.id, UAS#trans.method, Reply]),
    case Reply of
        ok ->
            Call1 = case ToTag of
                <<>> ->
                    Call;
                _ ->
                    nksip_call_lib:update_auth(DialogId, Req, Call)
            end,
            route_launch(UAS, Call1);
        forbidden ->
            nksip_call_uas:do_reply(forbidden, UAS, Call);
        authenticate ->
            nksip_call_uas:do_reply(authenticate, UAS, Call);
        {authenticate, Realm} ->
            nksip_call_uas:do_reply({authenticate, Realm}, UAS, Call);
        proxy_authenticate ->
            nksip_call_uas:do_reply(proxy_authenticate, UAS, Call);
        {proxy_authenticate, Realm} ->
            nksip_call_uas:do_reply({proxy_authenticate, Realm}, UAS, Call);
        _Other ->
            ?CALL_LOG(warning, "Invalid response calling authenticate/2: ~p", [_Other]),
            nksip_call_uas:do_reply({internal_error, "Service Response"}, UAS, Call)
    end.


%% @private
-spec route_launch(nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

route_launch(#trans{ruri=RUri}=UAS, #call{srv_id=SrvId}=Call) ->
    #uri{scheme=Scheme, user=User, domain=Domain} = RUri,
    Args = [Scheme, User, Domain, UAS#trans.request, Call],
    case nksip_util:user_callback(SrvId, sip_route, Args) of
        {ok, Reply} ->
            route_reply(Reply, UAS, Call);
        error ->
            nksip_call_uas:do_reply({internal_error, "Service Error"}, UAS, Call)
    end.
    

%% @private
-spec route_reply(term(), nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

route_reply(Reply, UAS, Call) ->
    #trans{ruri=RUri} = UAS,
    ?CALL_DEBUG("UAS ~p ~p route reply: ~p", [UAS#trans.id, UAS#trans.method, Reply]),
    Route = case Reply of
        {reply, Resp} ->
            {reply, Resp};
        {reply_stateless, Resp} ->
            {reply_stateless, Resp};
        process ->
            process;
        process_stateless ->
            process_stateless;
        proxy ->
            {proxy, RUri, []};
        {proxy, Uris} ->
            {proxy, Uris, []};
        {proxy, ruri, Opts} ->
            {proxy, RUri, Opts};
        {proxy, Uris, Opts} ->
            {proxy, Uris, Opts};
        proxy_stateless ->
            {proxy, RUri, [stateless]};
        {proxy_stateless, Uris} ->
            {proxy, Uris, [stateless]};
        {proxy_stateless, ruri, Opts} ->
            {proxy, RUri, [stateless|Opts]};
        {proxy_stateless, Uris, Opts} ->
            {proxy, Uris, [stateless|Opts]};
        strict_proxy ->
            {strict_proxy, []};
        {strict_proxy, Opts} ->
            {strict_proxy, Opts};
        _Invalid ->
            ?CALL_LOG(warning, "Invalid reply from route/5 callback: ~p", [_Invalid]),
            {reply_stateless, {internal_error, "Invalid Service Reply"}}
    end,
    do_route(Route, UAS, Call).


%% @private
-spec do_route({reply, nksip:sipreply()} | {reply_stateless, nksip:sipreply()} |
               process | process_stateless |
               {proxy, nksip:uri_set(), nksip:optslist()} |
               {strict_proxy, nksip:optslist()}, 
               nksip_call:trans(), nksip_call:call()) ->
    nksip_call:call().

do_route({reply, Reply}, UAS, Call) ->
    UAS1 = UAS#trans{stateless=false},
    nksip_call_uas:do_reply(Reply, UAS1, update(UAS1, Call));

do_route({reply_stateless, Reply}, UAS, Call) ->
    UAS1 = UAS#trans{stateless=true},
    nksip_call_uas:do_reply(Reply, UAS1, update(UAS1, Call));

%% CANCEL should have been processed already
do_route(process, #trans{method='CANCEL'}=UAS, Call) ->
    nksip_call_uas:do_reply(no_transaction, UAS, Call);

do_route(process, UAS, Call) ->
    UAS1 = UAS#trans{stateless=false},
    nksip_call_uas_process:process(UAS1, update(UAS1, Call));

%% CANCEL should have been processed already
do_route(process_stateless, #trans{method='CANCEL'}=UAS, Call) ->
    nksip_call_uas:do_reply(no_transaction, UAS, Call);

do_route(process_stateless, #trans{method='INVITE'}=UAS, Call) ->
    ?CALL_LOG(warning, "Invalid response 'process_stateless' for INVITE request "
                  " in route/5 callback", []),
    nksip_call_uas:do_reply({internal_error, "Invalid Service Response"}, UAS, Call);

do_route(process_stateless, UAS, Call) ->
    UAS1 = UAS#trans{stateless=true},
    nksip_call_uas_process:process(UAS1, update(UAS1, Call));

% We want to proxy the request
do_route({proxy, UriList, ProxyOpts}, UAS, Call) ->
    #trans{id=Id, opts=Opts, method=Method} = UAS,
    case nksip_call_proxy:route(UriList, ProxyOpts, UAS, Call) of
        noreply ->
            UAS1 = UAS#trans{status=finished},
            update(UAS1, Call);
        {fork, _, _, _} when Method=='CANCEL' ->
            nksip_call_uas:do_reply(no_transaction, UAS, Call);
        {fork, UAS1, UriSet, ProxyOpts1} ->
            % ProxyOpts may include record_route
            % TODO 16.6.4: If ruri or top route has sips, and not received with 
            % tls, must record_route. If received with tls, and no sips in ruri
            % or top route, must record_route also
            % Do not process dialogs on response
            UAS2 = UAS1#trans{opts=[no_dialog|Opts], stateless=false, from={fork, Id}},
            UAS3 = case Method of
                'ACK' ->
                    UAS2#trans{status=finished};
                _ ->
                    UAS2
            end,
            Call3 = update(UAS3, Call),
            nksip_call_fork:start(UAS3, UriSet, ProxyOpts1, Call3);
        {reply, SipReply, Call1} ->
            nksip_call_uas:do_reply(SipReply, UAS, Call1)
    end;


% Strict routing is here only to simulate an old SIP router and 
% test the strict routing capabilities of NkSIP 
do_route({strict_proxy, Opts}, #trans{request=Req}=UAS, Call) ->
    case Req#sipmsg.routes of
       [Next|_] ->
            ?CALL_LOG(info, "strict routing to ~p", [Next]),
            do_route({proxy, Next, [stateless|Opts]}, UAS, Call);
        _ ->
            nksip_call_uas:do_reply({internal_error, <<"Invalid Srict Routing">>}, UAS, Call)
    end.


