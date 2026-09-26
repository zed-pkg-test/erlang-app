-module(bmscl_durable_shard).

-export([placement/4]).

-spec placement(map(), term(), term(), term()) -> {ok, map()} | {error, term()}.
placement(Target0, Tenant0, Application0, Object0) when is_map(Target0) ->
    %% Re-normalize here instead of trusting callers to have passed through the
    %% route parser. This keeps shard construction fail-closed for internal
    %% callers and prevents hand-crafted targets from bypassing namespace,
    %% layout, protocol, or Firecracker requirements.
    case bmscl_faas_profile:normalize(Target0) of
        {ok, Normalized} ->
            Target = maps:merge(Target0, Normalized),
            case {bmscl_faas_profile:execution_class(Target),
                  bmscl_faas_profile:profile(Target)} of
                {durable_actor, durable_actor_v1} ->
                    build_placement(Target, Tenant0, Application0, Object0);
                {Class, Profile} ->
                    {error, {invalid_durable_target, Class, Profile}}
            end;
        {error, Reason} ->
            {error, {invalid_durable_target, Reason}}
    end;
placement(_, _, _, _) ->
    {error, invalid_durable_target}.

build_placement(Target, Tenant0, Application0, Object0) ->
    case {text(Tenant0, 1024), text(Application0, 1024), text(Object0, 4096),
          durable_namespace(maps:get(namespace, Target, undefined)),
          maps:find(virtual_shards, Target),
          maps:find(shards_per_actor, Target)} of
        {{ok, Tenant}, {ok, Application}, {ok, ObjectKey},
         {ok, Namespace}, {ok, VirtualShards}, {ok, ShardsPerActor}}
          when is_integer(VirtualShards), VirtualShards >= 64, VirtualShards =< 65536,
               is_integer(ShardsPerActor), ShardsPerActor > 0, ShardsPerActor =< 4096,
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
        {_, _, _, {error, _}, _, _} -> {error, invalid_durable_namespace};
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


durable_namespace(Value) when is_binary(Value),
                              byte_size(Value) > 0,
                              byte_size(Value) =< 128 ->
    case binary:match(Value, <<0>>) of
        nomatch ->
            case lists:all(fun namespace_byte/1, binary:bin_to_list(Value)) of
                true -> {ok, Value};
                false -> {error, invalid}
            end;
        _ -> {error, invalid}
    end;
durable_namespace(_) ->
    {error, invalid}.

namespace_byte(Byte) when Byte >= $a, Byte =< $z -> true;
namespace_byte(Byte) when Byte >= $A, Byte =< $Z -> true;
namespace_byte(Byte) when Byte >= $0, Byte =< $9 -> true;
namespace_byte($.) -> true;
namespace_byte($_) -> true;
namespace_byte($-) -> true;
namespace_byte(_) -> false.
