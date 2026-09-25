-module(bmscl_phoenix_connections).
-behaviour(gen_server).

-export([start_link/0, register/3, lookup/1, drain_deployment/2, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    connections = #{},
    monitors = #{}
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec register(pid(), map(), map()) -> {ok, reference()} | {error, term()}.
register(TransportPid, Target, Context)
  when is_pid(TransportPid), is_map(Target), is_map(Context) ->
    gen_server:call(?MODULE, {register, TransportPid, Target, Context});
register(_, _, _) ->
    {error, invalid_connection_registration}.

lookup(Ref) when is_reference(Ref) ->
    gen_server:call(?MODULE, {lookup, Ref});
lookup(_) ->
    {error, invalid_connection_ref}.

drain_deployment(DeploymentId, Reason) ->
    gen_server:call(?MODULE, {drain_deployment, DeploymentId, Reason}).

status() ->
    gen_server:call(?MODULE, status).

init([]) ->
    {ok, #state{}}.

handle_call({register, TransportPid, Target, Context}, _From, State0) ->
    case validate_target(Target) of
        ok ->
            case is_process_alive(TransportPid) of
                false ->
                    {reply, {error, transport_not_alive}, State0};
                true ->
                    DeploymentId = maps:get(deployment_id, Target),
                    case bmscl_deployment_manager:pin_deployment(DeploymentId) of
                        {ok, Pin} ->
                            case bmscl_deployment_manager:attach(Pin, TransportPid) of
                                ok ->
                                    Ref = make_ref(),
                                    Mon = erlang:monitor(process, TransportPid),
                                    Connection = #{
                                        ref => Ref,
                                        pid => TransportPid,
                                        deployment_id => DeploymentId,
                                        generation => DeploymentId,
                                        route_id => maps:get(route_id, Target, undefined),
                                        function_id => maps:get(function_id, Target, undefined),
                                        protocol => websocket,
                                        profile => phoenix_v1,
                                        state => open,
                                        context => Context
                                    },
                                    Connections1 = maps:put(Ref, Connection, State0#state.connections),
                                    Monitors1 = maps:put(Mon, Ref, State0#state.monitors),
                                    {reply, {ok, Ref},
                                     State0#state{connections = Connections1,
                                                  monitors = Monitors1}};
                                {error, Reason} ->
                                    _ = bmscl_deployment_manager:release_pin(Pin),
                                    {reply, {error, {deployment_attach_failed, Reason}}, State0}
                            end;
                        {error, Reason} ->
                            {reply, {error, {deployment_pin_failed, Reason}}, State0}
                    end
            end;
        {error, Reason} ->
            {reply, {error, Reason}, State0}
    end;
handle_call({lookup, Ref}, _From, State) ->
    {reply, maps:find(Ref, State#state.connections), State};
handle_call({drain_deployment, DeploymentId, Reason}, _From, State0) ->
    {Count, Connections1} =
        maps:fold(
          fun(Ref, Connection, {N, Acc}) ->
              case maps:get(deployment_id, Connection) =:= DeploymentId of
                  true ->
                      Pid = maps:get(pid, Connection),
                      Pid ! {bmscl_phoenix_drain, Ref, Reason},
                      {N + 1, maps:put(Ref, Connection#{state => draining}, Acc)};
                  false ->
                      {N, maps:put(Ref, Connection, Acc)}
              end
          end,
          {0, #{}},
          State0#state.connections),
    {reply, {ok, Count}, State0#state{connections = Connections1}};
handle_call(status, _From, State) ->
    Open = maps:fold(
      fun(_Ref, #{state := open}, N) -> N + 1;
         (_Ref, _Connection, N) -> N
      end, 0, State#state.connections),
    Draining = map_size(State#state.connections) - Open,
    {reply, #{total => map_size(State#state.connections),
              open => Open,
              draining => Draining}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Mon, process, _Pid, _Reason}, State0) ->
    case maps:take(Mon, State0#state.monitors) of
        error ->
            {noreply, State0};
        {Ref, Monitors1} ->
            {noreply, State0#state{
                monitors = Monitors1,
                connections = maps:remove(Ref, State0#state.connections)
            }}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
      fun(Ref, Connection) ->
          maps:get(pid, Connection) ! {bmscl_phoenix_drain, Ref, runtime_stopping}
      end,
      State#state.connections),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

validate_target(Target) ->
    case {bmscl_faas_profile:execution_class(Target),
          bmscl_faas_profile:profile(Target)} of
        {connection, phoenix_v1} ->
            bmscl_faas_profile:ensure_enabled(Target);
        {Class, Profile} ->
            {error, {invalid_phoenix_connection_target, Class, Profile}}
    end.
