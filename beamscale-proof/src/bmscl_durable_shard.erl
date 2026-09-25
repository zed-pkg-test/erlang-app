-module(bmscl_durable_shard).

-export([placement/4]).

-spec placement(map(), term(), term(), term()) -> {ok, map()} | {error, term()}.
placement(Target, Tenant0, Application0, Object0) when is_map(Target) ->
    case {bmscl_faas_profile:execution_class(Target),
          bmscl_faas_profile:profile(Target)} of
        {durable_actor, durable_actor_v1} ->
            build_placement(Target, Tenant0, Application0, Object0);
        {Class, Profile} ->
            {error, {invalid_durable_target, Class, Profile}}
    end;
placement(_, _, _, _) ->
    {error, invalid_durable_target}.

build_placement(Target, Tenant0, Application0, Object0) ->
    case {text(Tenant0, 1024), text(Application0, 1024), text(Object0, 4096),
          maps:find(namespace, Target),
          maps:find(virtual_shards, Target),
          maps:find(shards_per_actor, Target)} of
        {{ok, Tenant}, {ok, Application}, {ok, ObjectKey},
         {ok, Namespace}, {ok, VirtualShards}, {ok, ShardsPerActor}}
          when is_binary(Namespace),
               is_integer(VirtualShards), VirtualShards > 0,
               is_integer(ShardsPerActor), ShardsPerActor > 0,
               ShardsPerActor =< VirtualShards,
               VirtualShards rem ShardsPerActor =:= 0 ->
            Identity = {Tenant, Application, Namespace, ObjectKey},
            Hash = crypto:hash(sha256,
                               term_to_binary({<<"bmscl-durable-v1">>, Identity},
                                              [deterministic])),
            <<Prefix:64/unsigned-big, _/binary>> = Hash,
            VirtualShard = Prefix rem VirtualShards,
            ActorBucket = VirtualShard div ShardsPerActor,
            ActorKey = {Tenant, Application, Namespace, ActorBucket},
            {ok, #{
                tenant_id => Tenant,
                application_id => Application,
                namespace => Namespace,
                object_key => ObjectKey,
                virtual_shard => VirtualShard,
                actor_bucket => ActorBucket,
                actor_key => ActorKey,
                virtual_shards => VirtualShards,
                shards_per_actor => ShardsPerActor,
                deployment_id => maps:get(deployment_id, Target, undefined)
            }};
        {{error, _}, _, _, _, _, _} -> {error, invalid_tenant_id};
        {_, {error, _}, _, _, _, _} -> {error, invalid_application_id};
        {_, _, {error, _}, _, _, _} -> {error, invalid_object_key};
        _ -> {error, invalid_durable_route_layout}
    end.

text(Value, Max) when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< Max ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, Value};
        _ -> {error, invalid}
    end;
text(Value, Max) when is_list(Value) ->
    text(unicode:characters_to_binary(Value), Max);
text(_, _) ->
    {error, invalid}.
