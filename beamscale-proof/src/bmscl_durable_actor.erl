-module(bmscl_durable_actor).
-behaviour(gen_server).

-export([start/1, start/2, admit_turn/2, info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start(Placement) when is_map(Placement) ->
    Store = application:get_env(
              bmscl_supervisor, durable_store_module, bmscl_durable_store_redis),
    gen_server:start(?MODULE, {Placement, {store, Store}}, []);
start(_) ->
    {error, invalid_actor_start}.

%% Compatibility/test constructor. Production registry code uses start/1 so
%% ownership epochs always come from the authoritative durable store.
start(Placement, Epoch) when is_map(Placement), is_integer(Epoch), Epoch > 0 ->
    gen_server:start(?MODULE, {Placement, {fixed_epoch, Epoch}}, []);
start(_, _) ->
    {error, invalid_actor_start}.

admit_turn(Pid, Placement) when is_pid(Pid), is_map(Placement) ->
    gen_server:call(Pid, {admit_turn, Placement});
admit_turn(_, _) ->
    {error, invalid_turn}.

info(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, info);
info(_) ->
    {error, invalid_actor_pid}.

init({Placement, Ownership}) ->
    ActorKey = maps:get(actor_key, Placement),
    {Store, FixedEpoch} = case Ownership of
        {store, StoreModule} -> {StoreModule, undefined};
        {fixed_epoch, Epoch} -> {undefined, Epoch}
    end,
    {ok, #{
        actor_key => ActorKey,
        tenant_id => maps:get(tenant_id, Placement),
        application_id => maps:get(application_id, Placement),
        namespace => maps:get(namespace, Placement),
        actor_bucket => maps:get(actor_bucket, Placement),
        virtual_shards => maps:get(virtual_shards, Placement),
        shards_per_actor => maps:get(shards_per_actor, Placement),
        deployment_id => maps:get(deployment_id, Placement),
        store_module => Store,
        fixed_epoch => FixedEpoch,
        owner_epochs => #{},
        sequence => 0,
        seen_shards => #{}
    }}.

handle_call({admit_turn, Placement}, _From, State0) ->
    case placement_matches_actor(Placement, State0) of
        false ->
            {reply, {error, tenant_or_actor_mismatch}, State0};
        true ->
            VirtualShard = maps:get(virtual_shard, Placement),
            case ensure_owner_epoch(VirtualShard, Placement, State0) of
                {error, Reason, State1} ->
                    {reply, {error, Reason}, State1};
                {ok, OwnerEpoch, State1} ->
                    Sequence = maps:get(sequence, State1) + 1,
                    Seen0 = maps:get(seen_shards, State1),
                    Seen1 = maps:put(VirtualShard, true, Seen0),
                    Token = #{
                        %% epoch remains as a wire-compatibility alias. The
                        %% authoritative value is owner_epoch from durable store.
                        epoch => OwnerEpoch,
                        owner_epoch => OwnerEpoch,
                        sequence => Sequence,
                        virtual_shard => VirtualShard,
                        actor_bucket => maps:get(actor_bucket, State1),
                        object_key => maps:get(object_key, Placement),
                        actor_key => maps:get(actor_key, State1),
                        deployment_id => maps:get(deployment_id, State1)
                    },
                    {reply, {ok, Token},
                     State1#{sequence => Sequence, seen_shards => Seen1}}
            end
    end;
handle_call(info, _From, State) ->
    Info = maps:without([seen_shards, store_module, fixed_epoch], State),
    {reply, Info#{shard_count => map_size(maps:get(seen_shards, State))}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ensure_owner_epoch(VirtualShard, Placement, State0) ->
    OwnerEpochs = maps:get(owner_epochs, State0),
    case maps:find(VirtualShard, OwnerEpochs) of
        {ok, Epoch} ->
            {ok, Epoch, State0};
        error ->
            claim_owner_epoch(VirtualShard, Placement, State0)
    end.

claim_owner_epoch(VirtualShard, Placement, State0) ->
    case maps:get(fixed_epoch, State0) of
        Epoch when is_integer(Epoch), Epoch > 0 ->
            remember_owner_epoch(VirtualShard, Epoch, State0);
        undefined ->
            Store = maps:get(store_module, State0),
            OwnerScope = #{
                tenant_id => maps:get(tenant_id, Placement),
                application_id => maps:get(application_id, Placement),
                namespace => maps:get(namespace, Placement),
                virtual_shard => VirtualShard
            },
            try Store:claim_owner(OwnerScope) of
                {ok, Epoch} when is_integer(Epoch), Epoch > 0 ->
                    remember_owner_epoch(VirtualShard, Epoch, State0);
                {error, Reason} ->
                    {error, {durable_owner_claim_failed, Reason}, State0};
                Other ->
                    {error, {durable_owner_claim_invalid, Other}, State0}
            catch
                Class:Reason ->
                    {error, {durable_owner_claim_exception, Class, Reason}, State0}
            end
    end.

remember_owner_epoch(VirtualShard, Epoch, State0) ->
    Epochs0 = maps:get(owner_epochs, State0),
    State1 = State0#{owner_epochs => maps:put(VirtualShard, Epoch, Epochs0)},
    {ok, Epoch, State1}.

placement_matches_actor(Placement, State) ->
    maps:get(actor_key, Placement, undefined) =:= maps:get(actor_key, State)
    andalso maps:get(tenant_id, Placement, undefined) =:= maps:get(tenant_id, State)
    andalso maps:get(application_id, Placement, undefined) =:= maps:get(application_id, State)
    andalso maps:get(namespace, Placement, undefined) =:= maps:get(namespace, State)
    andalso maps:get(actor_bucket, Placement, undefined) =:= maps:get(actor_bucket, State)
    andalso maps:get(virtual_shards, Placement, undefined) =:= maps:get(virtual_shards, State)
    andalso maps:get(shards_per_actor, Placement, undefined) =:= maps:get(shards_per_actor, State)
    andalso maps:get(deployment_id, Placement, undefined) =:= maps:get(deployment_id, State)
    andalso valid_object_key(maps:get(object_key, Placement, undefined))
    andalso valid_virtual_shard(Placement, State).

valid_virtual_shard(Placement, State) ->
    VirtualShard = maps:get(virtual_shard, Placement, undefined),
    VirtualShards = maps:get(virtual_shards, State),
    ShardsPerActor = maps:get(shards_per_actor, State),
    ActorBucket = maps:get(actor_bucket, State),
    is_integer(VirtualShard)
    andalso VirtualShard >= 0
    andalso VirtualShard < VirtualShards
    andalso VirtualShard div ShardsPerActor =:= ActorBucket.

valid_object_key(Value) when is_binary(Value),
                             byte_size(Value) > 0,
                             byte_size(Value) =< 4096 ->
    binary:match(Value, <<0>>) =:= nomatch;
valid_object_key(_) ->
    false.
