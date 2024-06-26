%% -------------------------------------------------------------------
%%
%% uac_test: Basic Test Suite
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

-module(t03_uac).

-include_lib("eunit/include/eunit.hrl").
-include_lib("nksip/include/nksip.hrl").

-compile([export_all, nowarn_export_all]).


uac_gen() ->
    {setup, spawn,
        fun() -> start() end,
        fun(_) -> stop() end,
        [
            {timeout, 60, fun uac/0},
            {timeout, 60, fun info/0},
            {timeout, 60, fun message/0},
            {timeout, 60, fun timeout/0},
            {timeout, 60, fun bye_with_reason/0}
        ]
    }.


start() ->
    ?debugFmt("\n\nStarting ~p\n\n", [?MODULE]),
    tests_util:start_nksip(),
    {ok, _} = nksip:start_link(uac_test_client1, #{
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:uac_test_client1@nksip>",
        sip_listen => "sip:all:5070, <sip:all:5071;transport=tls>"}),

    {ok, _} = nksip:start_link(uac_test_client2, #{
        sip_from => "\"NkSIP Basic SUITE Test Client\" <sip:uac_test_client2@nksip>"}),

    timer:sleep(1000),
    ok.


stop() ->
    ok = nksip:stop(uac_test_client1),
    ok = nksip:stop(uac_test_client2),
    ?debugFmt("Stopping ~p", [?MODULE]),
    timer:sleep(500),
    ok.


uac() ->
    SipC1 = "sip:127.0.0.1:5070",

    {error, invalid_uri} = nksip_uac:options(uac_test_client2, "sip::a", []),
    {error, {invalid, <<"from">>}} = nksip_uac:options(uac_test_client2, SipC1, [{from, "<>"}]),
    {error, {invalid, <<"to">>}} = nksip_uac:options(uac_test_client2, SipC1, [{to, "<>"}]),
    {error, {invalid, <<"route">>}} = nksip_uac:options(uac_test_client2, SipC1, [{route, "<>"}]),
    {error, {invalid, <<"contact">>}} = nksip_uac:options(uac_test_client2, SipC1, [{contact, "<>"}]),
    {error, {invalid_config, cseq_num}} = nksip_uac:options(uac_test_client2, SipC1, [{cseq_num, -1}]),
    {error, service_not_started} = nksip_uac:options(none, SipC1, []),
    ?LOG_ERROR("Next 2 errors about 'too_many_calls' are expected"),
    nklib_counters:incr(nksip_calls, 1000000000),
    {error, too_many_calls} = nksip_uac:options(uac_test_client2, SipC1, []),
    nklib_counters:incr(nksip_calls, -1000000000),
    nklib_counters:incr({nksip_calls, uac_test_client2}, 1000000000),
    {error, too_many_calls} = nksip_uac:options(uac_test_client2, SipC1, []),
    nklib_counters:incr({nksip_calls, uac_test_client2}, -1000000000),

    Self = self(),
    Ref = make_ref(),
    Fun = fun(Reply) -> 
        case Reply of
            {req, Req, _Call} -> Self ! {Ref, {req, Req}};
            {resp, Code, Resp, _Call} -> Self ! {Ref, {resp, Code, Resp}};
            {error, Error} -> Self ! {Ref, {error, Error}}
        end
    end,

    CB = {callback, Fun},
    Hds = [{add, "x-nk-op", busy}, {add, "x-nk-prov", "true"}],

    ?LOG_INFO("Next two infos about connection error to port 50600 are expected"),
    {error, service_unavailable} =
        nksip_uac:options(uac_test_client2, "<sip:127.0.0.1:50600;transport=tcp>", []),
    
    % Async, error
    {async, _ReqId1} = nksip_uac:options(uac_test_client2, "<sip:127.0.0.1:50600;transport=tcp>",
                                        [async, CB, get_request]),
    receive 
        {Ref, {error, service_unavailable}} -> ok
        after 500 -> error(uac) 
    end,

    % Sync
    {ok, 200, Values2} = nksip_uac:options(uac_test_client2, SipC1, [{get_meta, [handle, call_id]}]),
    [{handle, RespId2}, {call_id, CallId2}] = Values2,
    {ok, CallId2} = nksip_response:call_id(RespId2),
    {error, _} = nksip_dialog:get_meta(status, RespId2),
    {error, invalid_dialog} = nksip_uac:options(RespId2, []),

    % Sync, callback for request
    {ok, 200, [{handle, RespId3}]} = 
        nksip_uac:options(uac_test_client2, SipC1, [CB, get_request, {get_meta, [handle]}]),
    {ok, CallId3} = nksip_response:call_id(RespId3),
    receive 
        {Ref, {req, #sipmsg{class={req, _}, call_id=CallId3}}} -> ok
        after 500 -> error(uac) 
    end,

    % Sync, callback for request and provisional response
    {ok, 486, [{call_id, CallId4}, {handle, RespId4}]} = 
        nksip_uac:invite(uac_test_client2, SipC1, [CB, get_request, {get_meta, [call_id, handle]}|Hds]),

    {ok, CallId4} = nksip_response:call_id(RespId4),
    % {ok, DlgId4} = nksip_dialog:get_handle(RespId4),
    receive 
        {Ref, {req, Req4}} -> 
            {ok, CallId4} = nksip_request:call_id(Req4)
        after 500 -> 
            error(uac) 
    end,
    receive 
        {Ref, {resp, 180, Resp4}} ->
            {ok, [{dialog_handle, DlgId4}, {call_id, CallId4}, {handle, RespId4_180}]} =
                nksip_response:get_metas([dialog_handle, call_id, handle], Resp4),
            {ok, CallId4} = nksip_response:call_id(RespId4_180),
            {ok, CallId4} = nksip_dialog:call_id(DlgId4)
        after 500 -> 
            error(uac) 
    end,

    % Async
    {async, ReqId6} = nksip_uac:invite(uac_test_client2, SipC1, [async, CB, get_request | Hds]),
    {ok, CallId6} = nksip_request:call_id(ReqId6),
    {ok, CallId6} = nksip_request:get_meta(call_id, ReqId6),
    receive 
        {Ref, {req, Req6}} -> 
            {ok, ReqId6} = nksip_request:get_handle(Req6),
            {ok, CallId6} = nksip_request:call_id(Req6)
        after 500 -> 
            error(uac) 
    end,
    receive 
        {Ref, {resp, 180, _}} -> ok
        after 500 -> error(uac) 
    end,
    receive 
        {Ref, {resp, 486, _}} -> ok
        after 500 -> error(uac) 
    end,
    ok.



info() ->
    SipC1 = "sip:127.0.0.1:5070",
    Hd1 = {add, <<"x-nk-op">>, <<"ok">>},
    {ok, 200, [{dialog, DialogId2}]} = nksip_uac:invite(uac_test_client2, SipC1, [Hd1]),
    ok = nksip_uac:ack(DialogId2, []),
    Fs = {get_meta, [<<"x-nk-method">>, <<"x-nk-dialog">>]},
    DialogId1 = nksip_dialog_lib:remote_id(DialogId2, uac_test_client1),

    {ok, 200, Values1} = nksip_uac:info(DialogId2, [Fs]),
    [{<<"x-nk-method">>, [<<"info">>]}, {<<"x-nk-dialog">>, [DialogId1]}] = Values1,

    % Now we forcefully stop dialog at uac_test_client1. At uac_test_client2 is still valid, and can send the INFO
    ok = nksip_dialog:stop(DialogId1),
    {ok, 481, []} = nksip_uac:info(DialogId2, []), 

    % The dialog at uac_test_client2, at receiving a 481 (even for INFO) is destroyed before the BYE
    {error, unknown_dialog} = nksip_uac:bye(DialogId2, []),
    ok.


timeout() ->
    SipC1 = "sip:127.0.0.1:5070",
    ok = nksip:update(uac_test_client2, #{sip_timer_t1=>10, sip_timer_c=>1}),

    ?LOG_NOTICE("Next notices about several timeouts are expected"),

    {ok, 408, [{reason_phrase, <<"Timer F Timeout">>}]} = 
        nksip_uac:options(uac_test_client2, "sip:127.0.0.1:9999", [{get_meta,[reason_phrase]}]),

    {ok, 408, [{reason_phrase, <<"Timer B Timeout">>}]} = 
        nksip_uac:invite(uac_test_client2, "sip:127.0.0.1:9999", [{get_meta,[reason_phrase]}]),

    % REGISTER sends a provisional response, but the timeout is the same
    Hd1 = {add, <<"x-nk-sleep">>, 2000},
    {ok, 408, [{reason_phrase, <<"Timer F Timeout">>}]} = 
        nksip_uac:options(uac_test_client2, SipC1, [Hd1, {get_meta, [reason_phrase]}]),

    % INVITE sends 
    Hds2 = [{add, "x-nk-op", busy}, {add, "x-nk-prov", "true"}, {add, "x-nk-sleep", 20000}],
    {ok, 408, [{reason_phrase, Reason}]} = 
        nksip_uac:invite(uac_test_client2, SipC1, [{get_meta, [reason_phrase]}|Hds2]),
    
    % TODO: Should fire timer C, sometimes it fires timer B 
    case Reason of
        <<"Timer C Timeout">> -> ok;
        <<"Timer B Timeout">> -> ok
    end,
    nksip_call:clear_all(),
    ok.


message() ->
    {Ref, Hd} = tests_util:get_ref(),
    {ok, 200, []} = nksip_uac:message(uac_test_client2, "sip:user@127.0.0.1:5070", [
                                      Hd, {expires, 10}, {content_type, "text/plain"},
                                      {body, <<"Message">>}]),

    receive 
        {Ref, {ok, 10, RawDate, <<"text/plain">>, <<"Message">>}} ->
            Date = httpd_util:convert_request_date(binary_to_list(RawDate)),
            true = nklib_util:timestamp() - nklib_util:gmt_to_timestamp(Date) < 2
        after 1000 -> 
            error(message)
    end,
    ok.


bye_with_reason() ->
    SipC1 = "sip:127.0.0.1:5070",
    Hd1 = {add, <<"x-nk-op">>, <<"ok">>},
    {ok, 200, [{dialog, DialogId2}]} = nksip_uac:invite(uac_test_client2, SipC1, [Hd1]),
    ok = nksip_uac:ack(DialogId2, []),
    Fs = {get_meta, [<<"x-nk-method">>, <<"x-nk-dialog">>]},
    DialogId1 = nksip_dialog_lib:remote_id(DialogId2, uac_test_client1),

    {ok, 200, Values1} = nksip_uac:info(DialogId2, [Fs]),
    [{<<"x-nk-method">>, [<<"info">>]}, {<<"x-nk-dialog">>, [DialogId1]}] = Values1,

    %% send a BYE with custom reason header
    {ok, 200, []} = nksip_uac:bye(DialogId2, [{reason, <<"custom reason">>}]),
    ok.

