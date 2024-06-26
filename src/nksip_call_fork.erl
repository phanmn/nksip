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

%% @doc Call Fork Management
-module(nksip_call_fork).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([start/4, cancel/2, response/4]).
-export_type([id/0]).

% -include_lib("nklib/include/nklib.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").

-type id() :: integer().

-type call() :: nksip_call:call().

-type fork() :: #fork{}.


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Starts a new Forking Proxy.
-spec start(nksip_call:trans(), nksip:uri_set(), nksip:optslist(),call()) ->
   call().

start(Trans, UriSet, ForkOpts, #call{forks=Forks}=Call) ->
    #trans{id=TransId, class=Class, request=Req, method=Method} = Trans,
    Fork = #fork{
        id = TransId,
        class = Class,
        start = nklib_util:timestamp(),
        request  = Req,
        method = Method,
        opts = ForkOpts,
        uriset = UriSet,
        uacs = [],
        pending = [],
        responses = [],
        final = false,
        meta = []
    },
    ?CALL_DEBUG("Fork ~p ~p started from UAS (~p)", [TransId, Method, ForkOpts]),
    Call1 = Call#call{forks=[Fork|Forks]},
    next(Fork, Call1).


%% @doc Tries to cancel an ongoing fork.
-spec cancel(id(), call()) ->
   call().

cancel(ForkId, #call{forks=Forks}=Call) ->
    case lists:keyfind(ForkId, #fork.id, Forks) of
        #fork{method='INVITE'}=Fork -> 
            ?CALL_DEBUG("Fork ~p cancelling requests", [ForkId]),
            Fork1 = Fork#fork{uriset=[]},
            cancel_all(Fork1, undefined, update(Fork1, Call));
        #fork{method=_Method}=Fork ->
            ?CALL_DEBUG("Fork ~p cannot cancel ~p", [ForkId, _Method]),
            Fork1 = Fork#fork{uriset=[]},
            update(Fork1, Call);
        false -> 
            ?CALL_LOG(info, "Fork ~p not found for CANCEL", [ForkId]),
            Call
    end.


%% @private
-spec next(fork(), call()) ->
   call().

next(#fork{pending=[]}=Fork, Call) ->
    #fork{id=Id, final=Final, method=Method, uriset=UriSet} = Fork,
    case Final of
        false ->
            case UriSet of
                [] when Method=='ACK' ->
                    delete(Fork, Call);
                [] ->
                    #sipmsg{class={resp, _Code, _}} = Resp = best_response(Fork),
                    ?CALL_DEBUG("Fork ~p ~p selected ~p response", [Id, Method, _Code]),
                    Call1 = send_reply(Resp, Fork, Call),
                    delete(Fork, Call1);
                [Next|Rest] ->
                    ?CALL_DEBUG("Fork ~p ~p launching next group", [Id, Method]),
                    Fork1 = Fork#fork{uriset=Rest},
                    launch(Next, Id, update(Fork1, Call))
            end;
        _ ->
            delete(Fork, Call)
    end;

next(#fork{id=_Id, method=_Method, pending=_Pending}, Call) ->
    ?CALL_DEBUG("Fork ~p ~p waiting, ~p pending: ~p",
                [_Id, _Method, length(_Pending), _Pending]),
    Call.


%% @private
-spec launch([nksip:uri()], id(), call()) ->
   call().

launch([], Id, Call) ->
    case lists:keyfind(Id, #fork.id, Call#call.forks) of
        #fork{} = Fork -> 
            next(Fork, Call);
        false -> 
            Call
    end;

launch([Uri|Rest], Id, Call) -> 
    #call{next=Next} = Call,
    Fork = lists:keyfind(Id, #fork.id, Call#call.forks),
    #fork{request=Req, method=Method, opts=Opts,
          uacs=UACs, pending=Pending, responses=Resps} = Fork,
    Req1 = Req#sipmsg{ruri=Uri, id=nklib_util:uid()},
    ?CALL_DEBUG("Fork ~p ~p launching to ~s", [Id, Method, nklib_unparse:uri(Uri)]),
    Fork1 = case Method of
        'ACK' -> 
            Fork#fork{uacs=[Next|UACs]};
        _ -> 
            Fork#fork{uacs=[Next|UACs], pending=[Next|Pending]}
    end,
    Call1 = update(Fork1, Call),
    Call2 = case nksip_call_uac_make:proxy_make(Req1, Opts) of
        {ok, Req2, Opts2} ->
            ?CALL_DEBUG("Fork ~p starting UAC ~p", [Id, Next]),
            % CAUTION: If NkSIP generates an automatic response (45xx) to this request,
            % it will call response/4 and can modify this same fork object
            ReqCall = nksip_call_uac:request(Req2, Opts2, {fork, Id}, Call1),
            ReqCall#call{next=Next+1};
        {reply, Reply} ->
            {Resp, _} = nksip_reply:reply(Req, Reply),
            ForkT = Fork#fork{responses=[Resp|Resps]},
            update(ForkT, Call1);
        {error, _Error} ->
            ?CALL_LOG(warning, "Error processing fork options: ~p, ~p: ~p",
                          [Uri, Opts, _Error]),
            Reply = {internal_error, <<"Invalid Fork Options">>},
            {Resp, _} = nksip_reply:reply(Req, Reply),
            ForkT = Fork#fork{responses=[Resp|Resps]},
            update(ForkT, Call1)
    end,
    %% CAUTION: This call to launch/3 can update the fork's state, can even delete it!
    launch(Rest, Id, Call2).


%% @private Called when a launched UAC has a response
-spec response(id(), integer(), nksip:response(),call()) ->
   call().

response(_, _, #sipmsg{class={resp, Code, _}}, Call) when Code < 101 ->
    Call;

response(Id, Pos, #sipmsg{vias=[_|Vias]}=Resp, #call{forks=Forks}=Call) ->
    #sipmsg{class={resp, Code, _}, to={_, _ToTag}} = Resp,
    case lists:keyfind(Id, #fork.id, Forks) of
        #fork{pending=Pending, uacs=UACs, method=_Method}=Fork ->
            ?CALL_DEBUG("Fork ~p ~p received ~p (~p, ~s)",
                        [Id, _Method, Code, Pos, _ToTag]),
            Resp1 = Resp#sipmsg{vias=Vias},
            case lists:member(Pos, Pending) of
                true ->
                    waiting(Code, Resp1, Pos, Fork, Call);
                false ->
                    case lists:member(Pos, UACs) of
                        true ->
                            ?CALL_DEBUG("Fork ~p ~p received new response ~p from ~s",
                                       [Id, _Method, Code, _ToTag]),
                            case Code>=200 andalso  Code<300 of
                                true -> 
                                    send_reply(Resp1, Fork, Call);
                                false -> 
                                    Call
                            end;
                        false ->
                            ?CALL_DEBUG("Fork ~p ~p received unexpected response "
                                        "~p from ~s", [Id, _Method, Code, _ToTag]),
                            Call
                    end
            end;
        false ->
            ?CALL_LOG(notice, "Received response ~p for nknown fork ~p", [Code, Id]),
            Call
    end.


%% @private
-spec waiting(nksip:sip_code(), nksip:response(), integer(), fork(), call()) ->
   call().

% 1xx
waiting(Code, Resp, _Pos, #fork{final=Final}=Fork, Call) when Code < 200 ->
    case Final of
        false -> 
            send_reply(Resp, Fork, Call);
        _ -> 
            Call
    end;
    
% 2xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 300 ->
    #fork{final=Final, pending=Pending} = Fork,
    Pending1 = Pending -- [Pos],
    Fork1 = Fork#fork{pending=Pending1, uriset=[]},
    Call1 = cancel_all(Fork1, {sip, 200, "Call completed elsewhere"}, Call),
    Fork2 = case Final of
        false -> 
            Fork1#fork{final='2xx'};
        _ -> 
            Fork1
    end,
    Call2 = send_reply(Resp, Fork2, Call1),
    next(Fork2, update(Fork2, Call2));

% 3xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 400 ->
    #fork{
        id = Id,
        final = Final,
        pending = Pending,
        responses = Resps,
        request = #sipmsg{ruri=RUri},
        opts = Opts
    } = Fork,
    #sipmsg{contacts=Contacts} = Resp,
    Pending1 = Pending -- [Pos],
    Fork1 = Fork#fork{pending=Pending1},
    case lists:member(follow_redirects, Opts) of
        true when Final==false, Contacts /= [] -> 
            Contacts1 = case RUri#uri.scheme of
                sips -> 
                    [Contact || #uri{scheme=sips}=Contact <- Contacts];
                _ -> 
                    Contacts
            end,
            ?CALL_DEBUG("Fork ~p redirect to ~p", [Id, nklib_unparse:uri(Contacts1)]),
            launch(Contacts1, Id, update(Fork1, Call));
        _ ->
            Fork2 = Fork1#fork{responses=[Resp|Resps]},
            next(Fork2, update(Fork2, Call))
    end;

% 45xx
waiting(Code, Resp, Pos, Fork, Call) when Code < 600 ->
    #fork{pending=Pending, responses=Resps} = Fork,
    Pending1 = Pending -- [Pos],
    Fork1 = Fork#fork{pending=Pending1, responses=[Resp|Resps]},
    next(Fork1, update(Fork1, Call));

% 6xx
waiting(Code, Resp, Pos, Fork, Call) when Code >= 600 ->
    #fork{final=Final, pending=Pending} = Fork,
    Pending1 = Pending -- [Pos],
    Fork1 = Fork#fork{pending=Pending1, uriset=[]},
    Call1 = cancel_all(Fork1, {sip, Code}, Call),
    case Final of
        false -> 
            Fork2 = Fork1#fork{final='6xx'},
            Call2 = send_reply(Resp, Fork2, Call1),
            next(Fork2, update(Fork2, Call2));
        _ ->
            next(Fork1, update(Fork1, Call1))
    end.


%% ===================================================================
%% Internal
%% ===================================================================

%% @private
-spec send_reply(nksip:response(), fork(), call()) ->
   call().

send_reply(Resp, Fork, Call) ->
    #sipmsg{class={resp, _Code, _}} = Resp,
    #fork{id=TransId, method=_Method, request=Req} = Fork,
    #call{trans=Trans} = Call,
    case lists:keyfind(TransId, #trans.id, Trans) of
        #trans{class=uas}=UAS ->
            ?CALL_DEBUG("Fork ~p ~p send reply to UAS: ~p", [TransId, _Method, _Code]),
            % Put the original transport back in the response
            Resp1 = Resp#sipmsg{nkport=Req#sipmsg.nkport},
            nksip_call_uas:do_reply({Resp1, []}, UAS, Call);
        _ ->
            ?CALL_DEBUG("Unknown UAS ~p received fork reply", [TransId]),
            Call
    end.


%% @private
-spec best_response(fork()) ->
    nksip:response().

best_response(#fork{request=Req, responses=Resps}) ->
    Sorted = lists:sort([
        if
            Code == 401; Code == 407 ->
                {3999, Resp};
            Code == 415; Code == 420; Code == 484 ->
                {4000, Resp};
            Code == 503 ->
                {5000, Resp#sipmsg{class={resp, 500, <<>>}}};
            Code >= 600 ->
                {Code, Resp};
            true ->
                {10*Code, Resp}
        end
        || #sipmsg{class={resp, Code, _Reason}}=Resp <- Resps
    ]),
    case Sorted of
        [{3999, Best}|_] ->
            Names = [<<"www-authenticate">>, <<"proxy-authenticate">>],
            Headers1 = [
                nklib_util:delete(Best#sipmsg.headers, Names) |
                [
                    nklib_util:extract(Headers, Names) || 
                    #sipmsg{class={resp, Code, _}, headers=Headers}
                    <- Resps, Code==401 orelse Code==407
                ]
            ],
            Best#sipmsg{headers=lists:flatten(Headers1)};
        [{_, Best}|_] ->
            Best;
        _ ->
            {Best, _} = nksip_reply:reply(Req, temporarily_unavailable),
            Best
    end.


%% @private
-spec cancel_all(fork(), nksip:error_reason()|undefined, call()) ->
   call().
    
cancel_all(#fork{method='INVITE', pending=[UAC|Rest]}=Fork, Reason, Call) ->
    Call1 = nksip_call_uac:cancel(UAC, [{reason, Reason}], undefined, Call),
    cancel_all(Fork#fork{pending=Rest}, Reason, Call1);

cancel_all(_Fork, _Reason, Call) ->
    Call.


%% @private 
update(#fork{id=Id}=Fork, #call{forks=[#fork{id=Id}|Rest]}=Call) ->
    Call#call{forks=[Fork|Rest]};

update(#fork{id=Id}=Fork, #call{forks=Forks}=Call) ->
    Call#call{forks=lists:keystore(Id, #fork.id, Forks, Fork)}.


%% @private
-spec delete(fork(), call()) ->
   call().

delete(#fork{id=Id, method=_Method}, #call{forks=Forks}=Call) ->
    ?CALL_DEBUG("Fork ~p ~p deleted", [Id, _Method]),
    Forks1 = lists:keydelete(Id, #fork.id, Forks),
    Call#call{forks=Forks1, hibernate=fork_finished}.



