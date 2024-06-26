%% -------------------------------------------------------------------
%%
%% tests_util: Utilities for the tests
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
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

-module(tests_util).

-export([start_nksip/0, start_debug/3, empty/0, wait/2]).
-export([get_ref/0, save_ref/1, update_ref/3, send_ref/2, dialog_update/2, session_update/2]).

-define(LOG_LEVEL, notice).    % debug, info, notice, warning, error

-ifdef(is_travis).
-define(WAIT_TIMEOUT, 100000).
-else.
-define(WAIT_TIMEOUT, 20000).
-endif.

start_nksip() ->
    nksip_app:start().


%%start(Name, Module, Opts) ->
%%    Opts1 = nklib_util:to_map(Opts),
%%    Opts2 = Opts1#{
%%        callback => Module
%%    },x
%%    {ok, _} = nksip:start(Name, Opts2),
%%    ok.


start_debug(Name, Module, Opts) ->
    nklib_log:debug(),
    Opts1 = nklib_util:to_map(Opts),
    Plugins = maps:get(plugins, Opts1, []),
    Opts2 = Opts1#{
        plugins => [nksip_trace | Plugins],
        callback => Module,
        log_level => debug,
        sip_trace => {console, all}
    },
    {ok, _} = nksip:start(Name, Opts2),
    ok.


empty() ->
    empty([]).

empty(Acc) -> 
    receive T -> empty([T|Acc]) after 0 -> Acc end.

wait(Ref, []) ->
    receive
        {Ref, Term} -> {error, {unexpected_term, Term, []}}
    after 0 ->
        ok
    end;
wait(Ref, List) ->
    receive 
        {Ref, Term} -> 
            % io:format("-------RECEIVED ~p\n", [Term]),
            case lists:member(Term, List) of
                true -> 
                    wait(Ref, List -- [Term]);
                false -> 
                    ?LOG_WARNING("Timer Test Wait unexpected term: ~p", [Term]),
                    wait(Ref, List)
                    % {error, {unexpected_term, Term, List}}
            end
    after   
        ?WAIT_TIMEOUT ->
            % io:format("------- WAIT TIMEOUT ~w\n", [List]),
            {error, {wait_timeout, List}}
    end.


get_ref() ->
    Ref = make_ref(),
    Hd = {add, "x-nk-reply", base64:encode(erlang:term_to_binary({Ref, self()}))},
    {Ref, Hd}.


save_ref(Req) ->
    case nksip_request:header(<<"x-nk-reply">>, Req) of
        {ok, [RepBin]} -> 
            {Ref, Pid} = erlang:binary_to_term(base64:decode(RepBin)),
            {ok, PkgId} = nksip_request:srv_id(Req),
            Dialogs = nkserver:get(PkgId, dialogs, []),
            {ok, DialogId} = nksip_dialog:get_handle(Req),
            ok =  nkserver:put(PkgId, dialogs, [{DialogId, Ref, Pid}|Dialogs]);
        {ok, _O} ->
            ok
    end.


update_ref(PkgId, Ref, DialogId) ->
    Dialogs = nkserver:get(PkgId, dialogs, []),
    ok =  nkserver:put(PkgId, dialogs, [{DialogId, Ref, self()}|Dialogs]).


send_ref(Msg, Req) ->
    {ok, DialogId} = nksip_dialog:get_handle(Req),
    {ok, PkgId} = nksip_request:srv_id(Req),
    Dialogs = nkserver:get(PkgId, dialogs, []),
    case lists:keyfind(DialogId, 1, Dialogs) of
        {DialogId, Ref, Pid}=_D -> 
            Pid ! {Ref, {PkgId, Msg}};
        false ->
            ok
    end.

dialog_update(Update, Dialog) ->
    {ok, PkgId} = nksip_dialog:srv_id(Dialog),
    case catch nkserver:get(PkgId, dialogs, []) of
        Dialogs when is_list(Dialogs) ->
            {ok, DialogId} = nksip_dialog:get_handle(Dialog),
            case lists:keyfind(DialogId, 1, Dialogs) of
                {DialogId, Ref, Pid} ->
                    SrvName = PkgId,
                    case Update of
                        start -> ok;
                        target_update -> Pid ! {Ref, {SrvName, target_update}};
                        {invite_status, confirmed} -> Pid ! {Ref, {SrvName, dialog_confirmed}};
                        {invite_status, {stop, Reason}} -> Pid ! {Ref, {SrvName, {dialog_stop, Reason}}};
                        {invite_status, _} -> ok;
                        {invite_refresh, SDP} -> Pid ! {Ref, {SrvName, {refresh, SDP}}};
                        invite_timeout -> Pid ! {Ref, {SrvName, timeout}};
                        {subscription_status, Status, Subs} -> 
                            {ok, Handle} = nksip_subscription:get_handle(Subs),
                            Pid ! {Ref, {subs, Status, Handle}};
                        stop -> ok
                    end;
                false -> 
                    none
            end;
        _ ->
            ok
    end.


session_update(Update, Dialog) ->
    {ok, PkgId} = nksip_dialog:srv_id(Dialog),
    Dialogs = nkserver:get(PkgId, dialogs, []),
    {ok, DialogId} = nksip_dialog:get_handle(Dialog),
    case lists:keyfind(DialogId, 1, Dialogs) of
        false -> 
            ok;
        {DialogId, Ref, Pid} ->
            SrvName = PkgId,
            case Update of
                {start, Local, Remote} ->
                    Pid ! {Ref, {SrvName, sdp_start}},
                    Sessions = nkserver:get(PkgId, sessions, []),
                     nkserver:put(PkgId, sessions, [{DialogId, Local, Remote}|Sessions]),
                    ok;
                {update, Local, Remote} ->
                    Pid ! {Ref, {SrvName, sdp_update}},
                    Sessions = nkserver:get(PkgId, sessions, []),
                     nkserver:put(PkgId, sessions, [{DialogId, Local, Remote}|Sessions]),
                    ok;
                stop ->
                    Pid ! {Ref, {SrvName, sdp_stop}},
                    ok
            end
    end.
