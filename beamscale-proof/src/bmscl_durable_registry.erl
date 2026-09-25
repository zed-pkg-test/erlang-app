-module(bmscl_durable_registry).
-behaviour(gen_server).

-export([start_link/0, locate/4, evict/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DURABLE_ARTIFACT_PROFILE, <<"bmscl-hosted-gleam-durable-actor-v1">>).

-record(state, {
    tenant_id = undefined,
    actors = #{},
    monitors = #{}
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
                    Tenant = maps:get(tenant_id, Placement),
                    case bind_tenant(Tenant, State0) of
                        {ok, BoundState} ->
                            locate_placement(Target, Placement, BoundState);
                        {error, TenantReason, BoundState} ->
                            {reply, {error, TenantReason}, BoundState}
                    end
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
    {reply, #{tenant_id => State#state.tenant_id,
              actor_count => map_size(Actors),
              actors => Actors}, State};
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

bind_tenant(Tenant, State = #state{tenant_id = undefined}) ->
    {ok, State#state{tenant_id = Tenant}};
bind_tenant(Tenant, State = #state{tenant_id = Tenant}) ->
    {ok, State};
bind_tenant(_Tenant, State = #state{tenant_id = Existing}) ->
    {error, {tenant_vm_mismatch, Existing}, State}.

locate_placement(Target, Placement, State0) ->
    ActorKey = maps:get(actor_key, Placement),
    case maps:find(ActorKey, State0#state.actors) of
        {ok, Actor} ->
            Pid = maps:get(pid, Actor),
            case is_process_alive(Pid) of
                false ->
                    State1 = remove_actor(ActorKey, Actor, State0),
                    start_actor(Target, Placement, State1);
                true ->
                    ExistingDeployment = maps:get(deployment_id, Actor, undefined),
                    RequestedDeployment = maps:get(deployment_id, Placement, undefined),
                    case ExistingDeployment =:= RequestedDeployment of
                        true ->
                            reply_with_turn(Pid, Placement, State0);
                        false ->
                            %% Never silently cross code generations. A durable
                            %% deployment migration must explicitly drain/evict
                            %% the old actor before the new generation owns it.
                            {reply,
                             {error, {durable_actor_deployment_mismatch,
                                      ExistingDeployment, RequestedDeployment}},
                             State0}
                    end
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
            case validate_pin_contract(Target, Placement, Pin) of
                {error, Reason} ->
                    _ = bmscl_deployment_manager:release_pin(Pin),
                    {reply, {error, Reason}, State0};
                ok ->
                    start_validated_actor(Placement, DeploymentId, Pin, State0)
            end
    end.

start_validated_actor(Placement, DeploymentId, Pin, State0) ->
    case bmscl_durable_actor:start(Placement) of
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
                        deployment_id => DeploymentId,
                        tenant_id => maps:get(tenant_id, Placement),
                        application_id => maps:get(application_id, Placement),
                        namespace => maps:get(namespace, Placement),
                        actor_bucket => maps:get(actor_bucket, Placement)
                    },
                    State1 = State0#state{
                        actors = maps:put(ActorKey, Actor, State0#state.actors),
                        monitors = maps:put(Mon, ActorKey, State0#state.monitors)
                    },
                    reply_with_turn(Pid, Placement, State1)
            end
    end.

validate_pin_contract(Target, Placement, Pin) ->
    Profile = maps:get(profile, Pin, undefined),
    Durable = maps:get(durable, Pin, undefined),
    PinDeployment = maps:get(deployment_id, Pin, undefined),
    DeploymentMatches =
        PinDeployment =:= maps:get(deployment_id, Target, undefined)
        andalso PinDeployment =:= maps:get(deployment_id, Placement, undefined),
    ExpectedNamespace = maps:get(namespace, Placement, undefined),
    ExpectedVirtualShards = maps:get(virtual_shards, Placement, undefined),
    ExpectedShardsPerActor = maps:get(shards_per_actor, Placement, undefined),
    case {Profile, Durable, DeploymentMatches} of
        {?DURABLE_ARTIFACT_PROFILE,
         #{namespace := Namespace,
           virtual_shards := VirtualShards,
           shards_per_actor := ShardsPerActor},
         true}
          when Namespace =:= ExpectedNamespace,
               VirtualShards =:= ExpectedVirtualShards,
               ShardsPerActor =:= ExpectedShardsPerActor ->
            ok;
        _ ->
            {error, {durable_artifact_contract_mismatch, Profile, Durable}}
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
                deployment_id => maps:get(deployment_id, Placement),
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


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

tenant_vm_binding_test() ->
    S0 = #state{},
    {ok, S1} = bind_tenant(<<"tenant-a">>, S0),
    ?assertEqual(<<"tenant-a">>, S1#state.tenant_id),
    {ok, S2} = bind_tenant(<<"tenant-a">>, S1),
    ?assertEqual(<<"tenant-a">>, S2#state.tenant_id),
    ?assertMatch({error, {tenant_vm_mismatch, <<"tenant-a">>}, _},
                 bind_tenant(<<"tenant-b">>, S2)).

-endif.
