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

%% @doc NkSIP Outbound Plugin
-module(nksip_outbound).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([proxy_opts/2, add_headers/6, check_several_reg_id/1]).
-export([registrar/1]).
-export([decode_flow/1]).

% -include_lib("nklib/include/nklib.hrl").
-include_lib("nkpacket/include/nkpacket.hrl").
-include_lib("nkserver/include/nkserver.hrl").
-include("nksip.hrl").
-include("nksip_call.hrl").


%% ===================================================================
%% Types
%% ===================================================================

%% @private Called when proxing a request, adds options only if we support outbound
%%
%% - For REGISTER requests, if we have 'path' in proxy opts, the
%%   request has "path" in Supported header and and the only Contact header 
%%   has a "reg-id" parameter, finds the connected transport of the request and
%%   - if we are the first hop, adds option {record_flow, {Pid, ob}}
%%   - if not, adds {record_flow, Pid}
%%
%% - For other requests, if the request supports outbound, we find the first Route
%%   that fits:
%%   - If we find a Route with a flow tag ("NkF..."):
%%     - If it is "outcoming" (the request came from the same flow as recorded),
%%       adds {record_flow, Pid}
%%     - If it is "incoming" (the request came from a different flow), adds a 
%%       {route_flow, nkport()}, and, if the Route has an "ob" parameter,
%%       adds also a {record_flow, Pid}.
%%       If the route has no "ob", but the Contact has, adds also {record_flow, Pid}
%%   - If we find a route without flow token but with an "ob" parameter, adds a     
%%     {record_flow, Pid}
%%
%% - {record_flow, Pid} parameter will be used in add_headers...
%%
%% - {route_flow, nkport()} will be used in nksip_call_uac_transp to route the 
%%   request using this transport

-spec proxy_opts(nksip:request(), map()) ->
    {ok, map()} | {error, Error}
    when Error :: flow_failed | forbidden.

proxy_opts(#sipmsg{srv_id=SrvId, class={req, 'REGISTER'}}=Req, Opts) ->
    #sipmsg{
        srv_id = SrvId,
        vias = Vias, 
        nkport = NkPort, 
        contacts = Contacts
    } = Req,
    #config{supported=Supported} = nksip_config:srv_config(SrvId),
    Opts1 = case
        lists:member(path, Opts) andalso
        nksip_sipmsg:supported(<<"path">>, Req) andalso
        lists:member(<<"outbound">>, Supported) andalso
        Contacts
    of
        [#uri{ext_opts=ContactOpts}] ->
            case lists:keymember(<<"reg-id">>, 1, ContactOpts) of
                true ->
                    case nksip_util:get_connected(SrvId, NkPort) of
                        [Pid|_] ->
                            case length(Vias)==1 of
                                true ->
                                    [{record_flow, {Pid, ob}}|Opts];
                                false ->
                                    [{record_flow, Pid}|Opts]
                            end;
                        _ ->
                            Opts
                    end;
                false ->
                    Opts
            end;
        _ ->
            Opts
    end,
    {ok, Opts1};

proxy_opts(Req, Opts) ->
    #sipmsg{ srv_id=SrvId, routes=Routes, contacts=Contacts, nkport=NkPort} = Req,
    #config{supported=Supported} = nksip_config:srv_config(SrvId),
    case
        nksip_sipmsg:supported(<<"outbound">>, Req) andalso
        lists:member(<<"outbound">>, Supported)
    of
        true ->
            case do_proxy_opts(Req, Opts, Routes) of
                {ok, Opts1} ->
                    case 
                        not lists:keymember(record_flow, 1, Opts1) andalso
                        Contacts
                    of
                       [#uri{opts=COpts}|_] ->
                            case lists:member(<<"ob">>, COpts) of
                                true ->
                                    Opts2 = case 
                                        nksip_util:get_connected(SrvId, NkPort)
                                    of
                                        [Pid|_] ->
                                            [{record_flow, Pid}|Opts1];
                                        [] ->
                                            Opts1
                                    end,
                                    {ok, Opts2};
                                false ->
                                    {ok, Opts1}
                            end;
                        _ ->
                            {ok, Opts1}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        false ->
            {ok, Opts}
    end.


%% @private
do_proxy_opts(_Req, Opts, []) ->
    {ok, Opts};

do_proxy_opts(Req, Opts, [Route|RestRoutes]) ->
    #sipmsg{srv_id=SrvId, nkport=NkPort} = Req,
    case nksip_util:is_local(SrvId, Route) andalso Route of
        #uri{user = <<"NkF", Token/binary>>, opts=RouteOpts} ->
            case decode_flow(Token) of
                {ok, #nkport{pid=Pid}=FlowTransp} ->
                    Opts1 = case flow_type(NkPort, FlowTransp) of
                        outcoming ->
                            % Came from the same flow
                            [{record_flow, Pid}|Opts];
                        incoming ->
                            [{route_flow, FlowTransp} |
                                case lists:member(<<"ob">>, RouteOpts) of
                                    true ->
                                        [{record_flow, Pid}|Opts];
                                    false ->
                                        Opts
                                end]
                    end,
                    {ok, Opts1};
                {error, flow_failed} ->
                    {error, flow_failed};
                {error, invalid} ->
                    ?CALL_LOG(notice, "Received invalid flow token", []),
                    {error, forbidden}
            end;
        #uri{opts=RouteOpts} ->
            case lists:member(<<"ob">>, RouteOpts) of
                true ->
                    Opts1 = case nksip_util:get_connected(SrvId, NkPort) of
                        [{_, Pid}|_] ->
                            [{record_flow, Pid}|Opts];
                        _ ->
                            Opts
                    end,
                    {ok, Opts1};
                false ->
                    do_proxy_opts(Req, Opts, RestRoutes)
            end;
        false ->
            {ok, Opts}
    end.


%% @private
flow_type(#nkport{transp=Transp, remote_ip=Ip, remote_port=Port, opts=Opts1},
          #nkport{transp=Transp, remote_ip=Ip, remote_port=Port, opts=Opts2}) ->
    case maps:get(path, Opts1, <<"/">>) == maps:get(path, Opts2, <<"/">>) of
        true ->
            outcoming;
        false ->
            incoming
    end;

flow_type(_, _) ->
    incoming.


%% @private Called from nksip_call_uac_transp to add headers to the request 
%% once we know the transport
%%
%% If we have a record_flow option, adds flow tokens to the Record-Route or
%% Path headers (Path will include "ob" if it was present in record_flow)
%%
%% When generating a Contact, for REGISTER requests adds reg-id if requested.
%% For others, if it is dialog-forming adds "ob" option.
-spec add_headers(nksip:request(), nksip:optslist(), nksip:scheme(),
                  nkpacket:transport(), binary(), inet:port_number()) ->
    nksip:request().

add_headers(Req, Opts, Scheme, Transp, ListenHost, ListenPort) ->
    #sipmsg{
        srv_id = SrvId,
        class = {req, Method},
        from = {From, _},
        vias = Vias,
        contacts = Contacts,
        headers = Headers
    } = Req,    
    {FlowPid, FlowOb} = case nklib_util:get_value(record_flow, Opts) of
        FlowPid0 when is_pid(FlowPid0) ->
            {FlowPid0, false};
        {FlowPid0, ob} when is_pid(FlowPid0) ->
            {FlowPid0, true};
        undefined ->
            {false, false}
    end,
    RouteUser = case FlowPid of
        false ->
            GlobalId = nksip_config:get_config(global_id),
            RouteBranch = case Vias of
                [#via{opts=RBOpts}|_] ->
                    nklib_util:get_binary(<<"branch">>, RBOpts);
                _ ->
                    <<>>
            end,
            RouteHash = nklib_util:hash({GlobalId, SrvId, RouteBranch}),
            <<"NkQ", RouteHash/binary>>;
        FlowPid ->
            FlowToken = encode_flow(FlowPid),
            <<"NkF", FlowToken/binary>>
    end,
    RecordRoute = case lists:member(record_route, Opts) of
        true when Method=='INVITE'; Method=='SUBSCRIBE'; Method=='NOTIFY';
                  Method=='REFER' ->
            nksip_util:make_route(sip, Transp, ListenHost, ListenPort,
                                       RouteUser, [<<"lr">>]);
        _ ->
            []
    end,
    Path = case lists:member(path, Opts) of
        true when Method=='REGISTER' ->
            case RouteUser of
                <<"NkQ", _/binary>> ->
                    nksip_util:make_route(sip, Transp, ListenHost, ListenPort,
                                               RouteUser, [<<"lr">>]);
                <<"NkF", _/binary>> ->
                    PathOpts = case FlowOb of
                        true ->
                            [<<"lr">>, <<"ob">>];
                        false ->
                            [<<"lr">>]
                    end,
                    nksip_util:make_route(sip, Transp, ListenHost, ListenPort,
                                               RouteUser, PathOpts)
            end;
        _ ->
            []
    end,
    Contacts1 = case Contacts==[] andalso lists:member(contact, Opts) of
        true ->
            Contact = nksip_util:make_route(Scheme, Transp, ListenHost,
                                                 ListenPort, From#uri.user, []),
            #uri{ext_opts=CExtOpts} = Contact,
            UUID = nkserver:get_uuid(SrvId),
            CExtOpts1 = [{<<"+sip.instance">>, <<$", UUID/binary, $">>}|CExtOpts],
            [make_contact(Req, Contact#uri{ext_opts=CExtOpts1}, Opts)];
        false ->
            Contacts
    end,
    Headers1 = nksip_headers:update(Headers, [
                                {before_multi, <<"record-route">>, RecordRoute},
                                {before_multi, <<"path">>, Path}]),
    Req#sipmsg{headers=Headers1, contacts=Contacts1}.


%% @private
-spec make_contact(nksip:request(), nksip:uri(), nksip:optslist()) ->
    nksip:uri().

make_contact(#sipmsg{class={req, 'REGISTER'}}=Req, Contact, Opts) ->
    case 
        nksip_sipmsg:supported(<<"outbound">>, Req) andalso
        nklib_util:get_integer(reg_id, Opts)
    of
        RegId when is_integer(RegId), RegId>0 ->
            #uri{ext_opts=CExtOpts1} = Contact,
            CExtOpts2 = [{<<"reg-id">>, nklib_util:to_binary(RegId)}|CExtOpts1],
            Contact#uri{ext_opts=CExtOpts2};
        _ ->
            Contact
    end;

% 'ob' parameter means we want to use the same flow for in-dialog requests
make_contact(Req, Contact, _Opts) ->
    case 
        nksip_sipmsg:supported(<<"outbound">>, Req)
        andalso nksip_sipmsg:is_dialog_forming(Req)
    of
        true ->
            #uri{opts=COpts} = Contact,
            Contact#uri{opts=nklib_util:store_value(<<"ob">>, COpts)};
        false ->
            Contact
    end.


%% @doc Checks if we have several contacts with a 'reg-id' having expires>0
-spec check_several_reg_id([#uri{}]) ->
    ok.

check_several_reg_id(Contacts) ->
    check_several_reg_id(Contacts, false).


%% @private
-spec check_several_reg_id([#uri{}], boolean()) ->
    ok.

check_several_reg_id([], _Found) ->
    ok;

check_several_reg_id([#uri{ext_opts=Opts}|Rest], Found) ->
    case nklib_util:get_value(<<"reg-id">>, Opts) of
        undefined ->
            check_several_reg_id(Rest, Found);
        _ ->
            Expires = case nklib_util:get_list(<<"expires">>, Opts) of
                [] ->
                    default;
                Expires0 ->
                    case catch list_to_integer(Expires0) of
                        Expires1 when is_integer(Expires1) ->
                            Expires1;
                        _ ->
                            default
                    end
            end,
            case Expires of
                0 ->
                    check_several_reg_id(Rest, Found);
                _ when Found ->
                    throw({invalid_request, "Several 'reg-id' Options"});
                _ ->
                    check_several_reg_id(Rest, true)
            end
    end.


%% @private
-spec registrar(nksip:request()) ->
    {boolean(), nksip:request()} | no_outbound.

registrar(Req) ->
    #sipmsg{ srv_id=SrvId, vias=Vias, nkport=NkPort} = Req,
    Config = nksip_config:srv_config(SrvId),
    case
        lists:member(<<"outbound">>, Config#config.supported) andalso
        nksip_sipmsg:supported(<<"outbound">>, Req)
    of
        true when length(Vias)==1 ->     % We are the first host
            #nkport{
                transp = Transp, 
                listen_ip = ListenIp, 
                listen_port = ListenPort
            } = NkPort,
            case nksip_util:get_connected(SrvId, NkPort) of
                [Pid|_] ->
                    Flow = encode_flow(Pid),
                    Host = nksip_util:get_listenhost(SrvId, ListenIp, []),
                    Path = nksip_util:make_route(sip, Transp, Host, ListenPort,
                                                      <<"NkF", Flow/binary>>, 
                                                      [<<"lr">>, <<"ob">>]),
                    Headers1 = nksip_headers:update(Req, 
                                                [{before_single, <<"path">>, Path}]),
                    Req1 = Req#sipmsg{headers=Headers1},
                    {true, Req1};
                [] ->
                    {false, Req}
            end;
        true ->
            case nksip_sipmsg:header(<<"path">>, Req, uris) of
                error ->
                    {error, {invalid_request, <<"Invalid Path">>}};
                [] ->
                    {false, Req};
                Paths ->
                    [#uri{opts=PathOpts}|_] = lists:reverse(Paths),
                    Ob = lists:member(<<"ob">>, PathOpts),
                    {Ob, Req}
            end;
        false ->
            no_outbound
    end.


decode_flow(Token) ->
    PidList = lists:flatten(["<0.", binary_to_list(Token), ">"]),
    case catch list_to_pid(PidList) of
        Pid when is_pid(Pid) ->
            case catch nkpacket:get_nkport(Pid) of
                {ok, FlowTransp} ->
                    {ok, FlowTransp};
                _ ->
                    {error, flow_failed}
            end;
        _ ->
            {error, invalid}
    end.


encode_flow(Pid) when is_pid(Pid) ->
    encode_flow(pid_to_list(Pid), []).

encode_flow([$<, $0, $.|Rest], Acc) -> encode_flow(Rest, Acc);
encode_flow([$>|_], Acc) -> list_to_binary(lists:reverse(Acc));
encode_flow([Ch|Rest], Acc) -> encode_flow(Rest, [Ch|Acc]).




