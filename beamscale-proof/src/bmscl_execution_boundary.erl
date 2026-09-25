-module(bmscl_execution_boundary).

-export([classify/1]).

-spec classify(map()) -> local_bare_process | firecracker | {error, term()}.
classify(Target) when is_map(Target) ->
    Profile = bmscl_faas_profile:profile(Target),
    Isolation = maps:get(isolation_class, Target, bare_process),
    classify(Profile, Isolation);
classify(_) ->
    {error, invalid_route_target}.

classify(undefined, bare_process) ->
    local_bare_process;
classify(undefined, firecracker) ->
    firecracker;
classify(phoenix_v1, firecracker) ->
    firecracker;
classify(durable_actor_v1, firecracker) ->
    firecracker;
classify(Profile, bare_process)
  when Profile =:= phoenix_v1; Profile =:= durable_actor_v1 ->
    {error, {experimental_profile_backend_mismatch,
             Profile, firecracker, bare_process}};
classify(Profile, Isolation)
  when Profile =:= phoenix_v1; Profile =:= durable_actor_v1 ->
    {error, {invalid_isolation_class, Isolation}};
classify(Profile, _Isolation) ->
    {error, {unsupported_execution_profile, Profile}}.
