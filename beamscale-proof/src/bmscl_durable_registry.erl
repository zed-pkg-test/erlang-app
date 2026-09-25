-module(bmscl_durable_registry).
-behaviour(gen_server).

-export([start_link/0, locate/4, evict/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    actors = #{},
    monitors = #{},
    next_epoch = 1
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

locate(Target, TenantId, ApplicationId, ObjectKey) ->
    gen_server:call(?MODULE, {locate, Target, TenantId, ApplicationId, ObjectKey}, infinity).

evict(ActorKey) ->
    gen_server:call(?MODULE, {evict, ActorKey}, infinity).

status() ->
    gen_server:call(?MODULE, status).

init([]) ->
    {ok, #state{}}.

handle_call({locate, Target, TenantId, ApplicationId, ObjectKey}, _From, State0) ->
    case bmscl_faas_profile:ensure_enabled(Target) of
        {error, Reason} ->
            {reply, {error, Reason}, State0};
        ok ->
            case bmscl_durable_shard:placement(Target, TenantId, ApplicationId, ObjectKey) of
                {error, Reason} ->
                    {reply, {error, Reason}, State0};
                {ok, Placement} ->
                    locate_placement(Target, Placement, State0)
            end
    end;
handle_call({evict, ActorKey}, _From, State0) ->
    case maps:take(ActorKey, State0#state.actors) of
        error ->
            {reply, {error, actor_not_found}, State0};
        {Actor, Actors1} ->
            Mon = maps:get(monitor, Actor),
            erlang:demonitor(Mon, [flush]),
            _ = catch gen_server:stop(maps:get(pid, Actor), normal, 5000),
            Monitors1 = maps:remove(Mon, State0#state.monitors),
            {reply, ok, State0#state{actors = Actors1, monitors = Monitors1}}
    end;
handle_call(status, _From, State) ->
    Actors = maps:map(
      fun(_Key, Actor) -> maps:without([monitor], Actor) end,
      State#state.actors),
    {reply, #{actor_count => map_size(Actors), actors => Actors}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Mon, process, _Pid, _Reason}, State0) ->
    case maps:take(Mon, State0#state.monitors) of
        error ->
            {noreply, State0};
        {ActorKey, Monitors1} ->
            {noreply, State0#state{
                monitors = Monitors1,
                actors = maps:remove(ActorKey, State0#state.actors)
            }}
    end;
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(
      fun(_Key, Actor) ->
          _ = catch gen_server:stop(maps:get(pid, Actor), normal, 1000)
      end,
      State#state.actors),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

locate_placement(Target, Placement, State0) ->
    ActorKey = maps:get(actor_key, Placement),
    case maps:find(ActorKey, State0#state.actors) of
        {ok, Actor} ->
            Pid = maps:get(pid, Actor),
            case is_process_alive(Pid) of
                true ->
                    reply_with_turn(Pid, Placement, State0);
                false ->
                    State1 = remove_actor(ActorKey, Actor, State0),
                    start_actor(Target, Placement, State1)
            end;
        error ->
            start_actor(Target, Placement, State0)
    end.

start_actor(Target, Placement, State0) ->
    DeploymentId = maps:get(deployment_id, Target),
    case bmscl_deployment_manager:pin_deployment(DeploymentId) of
        {error, Reason} ->
            {reply, {error, {deployment_pin_failed, Reason}}, State0};
        {ok, Pin} ->
            Epoch = State0#state.next_epoch,
            case bmscl_durable_actor:start(Placement, Epoch) of
                {error, Reason} ->
                    _ = bmscl_deployment_manager:release_pin(Pin),
                    {reply, {error, {actor_start_failed, Reason}}, State0};
                {ok, Pid} ->
                    case bmscl_deployment_manager:attach(Pin, Pid) of
                        {error, Reason} ->
                            _ = catch gen_server:stop(Pid, normal, 1000),
                            _ = bmscl_deployment_manager:release_pin(Pin),
                            {reply, {error, {deployment_attach_failed, Reason}}, State0};
                        ok ->
                            Mon = erlang:monitor(process, Pid),
                            ActorKey = maps:get(actor_key, Placement),
                            Actor = #{
                                pid => Pid,
                                monitor => Mon,
                                epoch => Epoch,
                                deployment_id => DeploymentId,
                                tenant_id => maps:get(tenant_id, Placement),
                                application_id => maps:get(application_id, Placement),
                                namespace => maps:get(namespace, Placement),
                                actor_bucket => maps:get(actor_bucket, Placement)
                            },
                            State1 = State0#state{
                                actors = maps:put(ActorKey, Actor, State0#state.actors),
                                monitors = maps:put(Mon, ActorKey, State0#state.monitors),
                                next_epoch = Epoch + 1
                            },
                            reply_with_turn(Pid, Placement, State1)
                    end
            end
    end.

reply_with_turn(Pid, Placement, State) ->
    case bmscl_durable_actor:admit_turn(Pid, Placement) of
        {ok, Token} ->
            Handle = #{
                pid => Pid,
                actor_key => maps:get(actor_key, Placement),
                tenant_id => maps:get(tenant_id, Placement),
                application_id => maps:get(application_id, Placement),
                namespace => maps:get(namespace, Placement),
                object_key => maps:get(object_key, Placement),
                virtual_shard => maps:get(virtual_shard, Placement),
                turn => Token
            },
            {reply, {ok, Handle}, State};
        {error, Reason} ->
            {reply, {error, {turn_admission_failed, Reason}}, State}
    end.

remove_actor(ActorKey, Actor, State0) ->
    Mon = maps:get(monitor, Actor),
    erlang:demonitor(Mon, [flush]),
    State0#state{
        actors = maps:remove(ActorKey, State0#state.actors),
        monitors = maps:remove(Mon, State0#state.monitors)
    }.
