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

%% @doc Call Worker Module
-module(nksip_call_worker).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([work/3, timeout/3]).
-export_type([work/0]).

-include("nksip.hrl").
-include("nksip_call.hrl").
-include_lib("nkserver/include/nkserver.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").


%% ===================================================================
%% Types
%% ===================================================================


-type work() :: 
    {send, nksip:request(), [nksip_uac:req_option()]} |
    {send, nksip:method(), nksip:user_uri(), [nksip_uac:req_option()]} |
    {send_dialog, nksip_dialog_lib:id(), nksip:method(), [nksip_uac:req_option()]} |
    {send_cancel, nksip_sipmsg:id(), nksip:sipreply()} |
    {cancel, nksip_sipmsg:id()} |
    {send_reply, nksip_sipmsg:id(), nksip:sipreply()} |
    {incoming, #sipmsg{}} | 
    {incoming, nkserver:id(), nkservice:id(), nksip:call_id(), nkpacket:nkport(), binary()} |
    info |
    get_all_dialogs | 
    {stop_dialog, nksip_dialog_lib:id()} |
    {apply_dialog, nksip_dialog_lib:id(), function()} |
    {get_authorized_list, nksip_dialog_lib:id()} | 
    {clear_authorized_list, nksip_dialog_lib:id()} |
    get_all_transactions | 
    {apply_transaction, nksip_sipmsg:id(), function()} |
    {apply_sipmsg, nksip_sipmsg:id(), function()}.



%% ===================================================================
%% Call works
%% ===================================================================


%% @private
-spec work(work(), {pid(), term()}|none, nksip_call:call()) ->
    nksip_call:call().

work({send, Req, Opts}, From, Call) ->
    nksip_call_uac:request(Req, Opts, {srv, From}, Call);

work({send, Method, Uri, Opts}, From, Call) ->
    #call{srv_id=SrvId, call_id=CallId} = Call,
    case nksip_call_uac_make:make(SrvId, Method, Uri, CallId, Opts) of
        {ok, Req, ReqOpts} ->
            work({send, Req, ReqOpts}, From, Call);
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            Call
    end;

work({send_dialog, DialogId, Method, Opts}, From, Call) ->
    case nksip_call_uac_dialog:make(DialogId, Method, Opts, Call) of
        {ok, RUri, Opts1, Call1} ->
            work({send, Method, RUri, Opts1}, From, Call1);
        {error, Error} ->
            gen_server:reply(From, {error, Error}),
            Call
    end;

work({send_cancel, ReqId, Opts}, From, Call) ->
    case is_list(Opts) of
        true ->
            ok;
        false ->
            error(cancel1)
    end,
    case get_trans_id(ReqId, Call) of
        {ok, TransId} ->
            nksip_call_uac:cancel(TransId, Opts, {srv, From}, Call);
        _ ->
            gen_server:reply(From, {error, unknown_request}),
            Call
    end;

work({send_reply, ReqId, SipReply}, From, Call) ->
    case get_trans(ReqId, Call) of
        {ok, #trans{class=uas}=UAS} ->
            {Reply, Call1} = nksip_call_uas:reply(SipReply, UAS, Call),
            gen_server:reply(From, Reply),
            Call1;
        _ ->
            gen_server:reply(From, {error, invalid_call}),
            Call
    end;

work({incoming, #sipmsg{class={req, _}}=Req}, _From, Call) ->
    Call2 = save_destination(Req, Call),
    nksip_call_uas:request(Req, Call2);

work({incoming, #sipmsg{class={resp, _, _}}=Resp}, none, Call) ->
    case nksip_call_uac:is_stateless(Resp) of
        true ->
            nksip_call_proxy:response_stateless(Resp, Call);
        false ->
            nksip_call_uac:response(Resp, Call)
    end;

work({incoming, NkPort, Msg}, _From, Call) ->
    #call{srv_id=SrvId, call_id=CallId} = Call,
    case nksip_parse:packet(SrvId, CallId, NkPort, Msg) of
        {ok, SipMsg} ->
             ?CALL_SRV(SrvId, nksip_connection_recv, [SipMsg, Msg]),
            work({incoming, SipMsg}, none, Call);
        {error, _Error} ->
            ?CALL_LOG(warning, "Error parsing SipMsg1: ~p", [_Error]),
            Call;
        {reply_error, _Error, Reply} ->
            case nksip_util:get_connected(SrvId, NkPort) of
                [Pid|_] ->
                    case nkpacket_connection:send(Pid, Reply) of
                        ok ->
                            ok;
                        {error, _SendError} ->
                            ?CALL_LOG(warning, "Error parsing SipMsg2: ~p", [_Error])
                    end;
                [] ->
                    ?CALL_LOG(warning, "Error parsing SipMsg3: ~p", [_Error])
            end,
            Call
    end;

work(get_all_dialogs, From, #call{dialogs=Dialogs}=Call) ->
    Ids = [nksip_dialog_lib:get_handle(Dialog) || Dialog <- Dialogs],
    gen_server:reply(From, {ok, Ids}),
    Call;

work({stop_dialog, DialogId}, From, Call) ->
    case get_dialog(DialogId, Call) of
        {ok, Dialog} ->
            gen_statem:reply(From, ok),
            nksip_call_dialog:stop(forced, Dialog, Call);
        not_found ->
            gen_statem:reply(From, {error, unknown_dialog}),
            Call
    end;

work({apply_dialog, DialogId, Fun}, From, Call) ->
    case get_dialog(DialogId, Call) of
        {ok, Dialog} ->
            case catch Fun(Dialog) of
                {Reply, {update, #dialog{}=Dialog1}} ->
                    gen_server:reply(From, {apply, Reply}),
                    nksip_call_dialog:store(Dialog1, Call);
                Reply ->
                    gen_server:reply(From, {apply, Reply}),
                    Call
            end;
        not_found ->
            gen_server:reply(From, {error, unknown_dialog}),
            Call
    end;
    
work({get_authorized_list, DlgId}, From, #call{auths=Auths}=Call) ->
    List = [{Transp, Ip, Port} || {D, Transp, Ip, Port} <- Auths, D==DlgId],
    gen_server:reply(From, {ok, List}),
    Call;

work({clear_authorized_list, DlgId}, From, #call{auths=Auths}=Call) ->
    Auths1 = [{D, Transp, Ip, Port} || {D, Transp, Ip, Port} <- Auths, D/=DlgId],
    gen_server:reply(From, ok),
    Call#call{auths=Auths1};

work(get_all_transactions, From, #call{trans=Trans}=Call) ->
    Ids = [{Class, Id} || #trans{id=Id, class=Class} <- Trans],
    gen_server:reply(From, {ok, Ids}),
    Call;

work({apply_transaction, MsgId, Fun}, From, Call) ->
    case get_trans(MsgId, Call) of
        {ok, Trans} ->
            gen_server:reply(From, {apply, catch Fun(Trans)});
        not_found ->  
            gen_server:reply(From, {error, unknown_transaction})
    end,
    Call;

work({apply_sipmsg, MsgId, Fun}, From, Call) ->
    case get_sipmsg(MsgId, Call) of
        {ok, Msg} ->
            gen_server:reply(From, {apply, catch Fun(Msg)}),
            Call;
        not_found ->
            gen_server:reply(From, {error, unknown_sipmsg}),
            Call
    end;

work(info, From, Call) ->
    #call{
        srv_id = SrvId,
        call_id = CallId,
        trans = Trans, 
        dialogs = Dialogs,
        events = ProvEvents
    } = Call,
    InfoTrans = lists:map(
        fun(#trans{id=Id, class=Class, method=Method, 
                   status=Status, timeout_timer=Timeout}) ->
            T = case Timeout of
                {Tag, Timer} ->
                    {Tag, erlang:read_timer(Timer)};
                undefined ->
                    undefined
            end,
            {trans, SrvId, CallId, Id, Class, Method, Status, T}
        end,
        Trans),
    InfoDialog = lists:map(
        fun(#dialog{id=DlgId, invite=Invite, subscriptions=Subs}) ->
            Inv = case Invite of
                #invite{status=Status, timeout_timer=Timer} ->
                    T = case Timer of
                        Timer when is_reference(Timer) ->
                            erlang:read_timer(Timer);
                        undefined ->
                            undefined
                    end,
                    {Status, T};
                undefined ->
                    undefined
            end,
            Ev = [
                    {EvId, Status, Class, erlang:read_timer(Exp)}
                    ||
                    #subscription{id=EvId, status=Status, class=Class, timer_expire=Exp} 
                    <- Subs
                ],
            {dlg, SrvId, DlgId, {invite, Inv}, {event, Ev}}
        end,
        Dialogs),
    InfoProvEvents = case ProvEvents of
        [] ->
            [];
        _ ->
            [{prov_events, length(ProvEvents)}]
    end,
    gen_server:reply(From, InfoTrans++InfoDialog++InfoProvEvents),
    Call;

work(crash, _, _) ->
    error(forced_crash).


%% ===================================================================
%% Call timeouts
%% ===================================================================


%% @private
-spec timeout(term(), reference(), nksip_call:call()) ->
    nksip_call:call().

timeout({uac, Tag, Id}, _Ref, Call) ->
    nksip_call_uac_timer:timer(Tag, Id, Call);

timeout({uas, Tag, Id}, _Ref, Call) ->
    nksip_call_uas_timer:timer(Tag, Id, Call);

timeout({dlg, Tag, Id}, _Ref, Call) ->
    nksip_call_dialog:timer(Tag, Id, Call);

timeout({remove_prov_event, Id}, _Ref, Call) ->
    nksip_call_event:remove_prov_event(Id, Call).



%% ===================================================================
%% Internal
%% ===================================================================



%% @private
-spec get_trans_id(nksip_sipmsg:id(), nksip_call:call()) ->
    {ok, nksip_call:trans_id()} | not_found.

get_trans_id(SipMsgId, #call{msgs=Msgs}) ->
    case lists:keyfind(SipMsgId, 1, Msgs) of
        {_, TransId, _DialogId} ->
            {ok, TransId};
        false ->
            not_found
    end.


%% @private
-spec get_trans(nksip_sipmsg:id(), nksip_call:call()) ->
    {ok, nksip_call:trans()} | not_found.

get_trans(SipMsgId, #call{trans=AllTrans}=Call) ->
    case get_trans_id(SipMsgId, Call) of
        {ok, TransId} ->
            case lists:keyfind(TransId, #trans.id, AllTrans) of
                #trans{}=Trans ->
                    {ok, Trans};
                false ->
                    not_found
            end;
        not_found ->
            not_found
    end.


%% @private
-spec get_sipmsg(nksip_sipmsg:id(), nksip_call:call()) ->
    {ok, nksip:request()|nksip:response()} | not_found.

get_sipmsg(SipMsgId, Call) ->
    case get_trans(SipMsgId, Call) of
        {ok, #trans{request=#sipmsg{id=SipMsgId}=Req}} ->
            {ok, Req};
        {ok, #trans{response=#sipmsg{id=SipMsgId}=Resp}} ->
            {ok, Resp};
        _ ->
            not_found
    end.


%% @private
-spec get_dialog(nksip_dialog_lib:id(), nksip_call:call()) ->
    {ok, #dialog{}} | not_found.

get_dialog(DialogId, #call{dialogs=Dialogs}) ->
    case lists:keyfind(DialogId, #dialog.id, Dialogs) of
        false ->
            not_found;
        Dialog ->
            {ok, Dialog}
    end.


%% @doc Cache in call information to reach this Via,
%% generated at UAS to be used later as UAC in a reversed dialog
save_destination(#sipmsg{vias=[Via|_], nkport=NkPort}, Call) ->
    #via{transp=Transp, domain=Domain, port=Port} = Via,
    #nkport{pid=Pid} = NkPort,
    #call{dests = Dests1} = Call,
    Dests2 = Dests1#{{Transp, Domain, Port} => Pid},
    Call#call{dests=Dests2}.






