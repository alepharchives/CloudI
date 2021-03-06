%%% -*- coding: utf-8; Mode: erlang; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*-
%%% ex: set softtabstop=4 tabstop=4 shiftwidth=4 expandtab fileencoding=utf-8:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI (Abstract) Map-Reduce Job==
%%% This module provides an Erlang behaviour for fault-tolerant,
%%% database agnostic map-reduce.  See the hexpi test for example usage.
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2012, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2012 Michael Truog
%%% @version 1.1.0 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_job_map_reduce).
-author('mjtruog [at] gmail (dot) com').

-behaviour(cloudi_job).

%% external interface

-ifdef(ERLANG_OTP_VER_R14).
%% behavior callbacks
-export([behaviour_info/1]).
-endif.

%% cloudi_job callbacks
-export([cloudi_job_init/3,
         cloudi_job_handle_request/11,
         cloudi_job_handle_info/3,
         cloudi_job_terminate/2]).

-include_lib("cloudi_core/include/cloudi_logger.hrl").

-define(DEFAULT_MAP_REDUCE_MODULE,     undefined).
-define(DEFAULT_MAP_REDUCE_ARGUMENTS,         []).
-define(DEFAULT_CONCURRENCY,                 1.0). % schedulers multiplier

-record(state,
    {
        map_reduce_module,
        map_reduce_state,
        map_count,
        map_requests    % orddict trans_id -> send_args
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%%------------------------------------------------------------------------
%%% Callback functions from behavior
%%%------------------------------------------------------------------------

-ifdef(ERLANG_OTP_VER_R14).

-spec behaviour_info(atom()) -> 'undefined' | [{atom(), byte()}].

behaviour_info(callbacks) ->
    [
        {cloudi_job_map_reduce_new, 2},
        {cloudi_job_map_reduce_send, 2},
        {cloudi_job_map_reduce_resend, 2},
        {cloudi_job_map_reduce_recv, 7}
    ];
behaviour_info(_) ->
    undefined.

-else. % Erlang version must be >= R15

-callback cloudi_job_map_reduce_new(ModuleReduceArgs :: list(),
                                    Dispatcher :: pid()) ->
    ModuleReduceState :: any().

-callback cloudi_job_map_reduce_send(ModuleReduceState :: any(),
                                     Dispatcher :: pid()) ->
    {'ok', SendArgs :: list(), NewModuleReduceState :: any()} |
    {'error', Reason :: any()}.

-callback cloudi_job_map_reduce_resend(SendArgs :: list(),
                                       ModuleReduceState :: any()) ->
    {'ok', NewSendArgs :: list(), NewModuleReduceState :: any()} |
    {'error', Reason :: any()}.

-callback cloudi_job_map_reduce_recv(SendArgs :: list(),
                                     ResponseInfo :: any(),
                                     Response :: any(),
                                     Timeout :: non_neg_integer(),
                                     TransId :: binary(),
                                     ModuleReduceState :: any(),
                                     Dispatcher :: pid()) ->
    {'ok', NewModuleReduceState :: any()} |
    {'error', Reason :: any()}.

-endif.

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_job
%%%------------------------------------------------------------------------

cloudi_job_init(Args, _Prefix, Dispatcher) ->
    Defaults = [
        {map_reduce,             ?DEFAULT_MAP_REDUCE_MODULE},
        {map_reduce_args,        ?DEFAULT_MAP_REDUCE_ARGUMENTS},
        {concurrency,            ?DEFAULT_CONCURRENCY}],
    [MapReduceModule, MapReduceArguments, Concurrency] =
        cloudi_proplists:take_values(Defaults, Args),
    true = is_atom(MapReduceModule) and (MapReduceModule /= undefined),
    true = is_list(MapReduceArguments),
    MapReduceState =
        MapReduceModule:cloudi_job_map_reduce_new(MapReduceArguments,
                                                  Dispatcher),
    MapCount = cloudi_configurator:concurrency(Concurrency),
    case map_send(MapCount, orddict:new(), Dispatcher,
                  MapReduceModule, MapReduceState) of
        {ok, MapRequests, NewMapReduceState} ->
            {ok, #state{map_reduce_module = MapReduceModule,
                        map_reduce_state = NewMapReduceState,
                        map_count = MapCount,
                        map_requests = MapRequests}};
        {error, _} = Error ->
            Error
    end.

cloudi_job_handle_request(_Type, _Name, _Pattern, _RequestInfo, _Request,
                          _Timeout, _Priority, _TransId, _Pid,
                          State, _Dispatcher) ->
    {reply, <<>>, State}.

cloudi_job_handle_info({timeout_async_active, TransId},
                       #state{map_reduce_module = MapReduceModule,
                              map_reduce_state = MapReduceState,
                              map_requests = MapRequests} = State,
                       _Dispatcher) ->
    SendArgs = orddict:fetch(TransId, MapRequests),
    NextMapRequests = orddict:erase(TransId, MapRequests),
    case MapReduceModule:cloudi_job_map_reduce_resend(SendArgs,
                                                      MapReduceState) of
        {ok, NewSendArgs, NewMapReduceState} ->
            case erlang:apply(cloudi_job, send_async_active, NewSendArgs) of
                {ok, NewTransId} ->
                    NewMapRequests = orddict:store(NewTransId,
                                                   NewSendArgs,
                                                   NextMapRequests),
                    {noreply,
                     State#state{map_reduce_state = NewMapReduceState,
                                 map_requests = NewMapRequests}};
                {error, _} = Error ->
                    {stop, Error, State}
            end;
        {error, _} = Error ->
            {stop, Error, State}
    end;

cloudi_job_handle_info({return_async_active, _Name, _Pattern,
                        ResponseInfo, Response,
                        Timeout, TransId},
                       #state{map_reduce_module = MapReduceModule,
                              map_reduce_state = MapReduceState,
                              map_requests = MapRequests} = State,
                       Dispatcher) ->
    SendArgs = orddict:fetch(TransId, MapRequests),
    case MapReduceModule:cloudi_job_map_reduce_recv(SendArgs,
                                                    ResponseInfo, Response,
                                                    Timeout, TransId,
                                                    MapReduceState,
                                                    Dispatcher) of
        {ok, NextMapReduceState} ->
            case map_send(orddict:erase(TransId, MapRequests),
                          Dispatcher, MapReduceModule, NextMapReduceState) of
                {ok, NewMapRequests, NewMapReduceState} ->
                    {noreply,
                     State#state{map_reduce_state = NewMapReduceState,
                                 map_requests = NewMapRequests}};
                {error, _} = Error ->
                    {stop, Error, State}
            end;
        {done, NewMapReduceState} ->
            NewMapRequests = orddict:erase(TransId, MapRequests),
            {noreply,
             State#state{map_reduce_state = NewMapReduceState,
                         map_requests = NewMapRequests}};
        {error, _} = Error ->
            {stop, Error, State}
    end;

cloudi_job_handle_info(Request, State, _) ->
    ?LOG_WARN("Unknown info \"~p\"", [Request]),
    {noreply, State}.

cloudi_job_terminate(_, #state{}) ->
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

map_send(MapRequests, Dispatcher, MapReduceModule, MapReduceState) ->
    map_send(1, MapRequests, Dispatcher, MapReduceModule, MapReduceState).

map_send(0, MapRequests, _Dispatcher, _MapReduceModule, MapReduceState) ->
    {ok, MapRequests, MapReduceState};

map_send(Count, MapRequests, Dispatcher, MapReduceModule, MapReduceState) ->
    case MapReduceModule:cloudi_job_map_reduce_send(MapReduceState,
                                                    Dispatcher) of
        {ok, SendArgs, NewMapReduceState} ->
            case erlang:apply(cloudi_job, send_async_active, SendArgs) of
                {ok, TransId} ->
                    map_send(Count - 1,
                             orddict:store(TransId, SendArgs, MapRequests),
                             Dispatcher, MapReduceModule, NewMapReduceState);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

