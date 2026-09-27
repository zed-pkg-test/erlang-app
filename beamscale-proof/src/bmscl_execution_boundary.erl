-module(bmscl_execution_boundary).

-export([classify/1]).

-spec classify(map()) -> local_bare_process | firecracker | {error, term()}.
classify(Target) when is_map(Target) ->
    case bmscl_faas_profile:normalize(Target) of
        {error, Reason} ->
            {error, Reason};
        {ok, ProfileFields} ->
            Canonical = maps:merge(Target, ProfileFields),
            classify_canonical(
              bmscl_faas_profile:profile(Canonical),
              maps:get(isolation_class, Canonical, bare_process))
    end;
classify(_) ->
    {error, invalid_route_target}.

classify_canonical(undefined, bare_process) ->
    local_bare_process;
classify_canonical(undefined, firecracker) ->
    firecracker;
classify_canonical(phoenix_v1, firecracker) ->
    firecracker;
classify_canonical(durable_actor_v1, firecracker) ->
    firecracker;
classify_canonical(Profile, bare_process)
  when Profile =:= phoenix_v1; Profile =:= durable_actor_v1 ->
    {error, {experimental_profile_backend_mismatch,
             Profile, firecracker, bare_process}};
classify_canonical(Profile, Isolation)
  when Profile =:= phoenix_v1; Profile =:= durable_actor_v1 ->
    {error, {invalid_isolation_class, Isolation}};
classify_canonical(undefined, Isolation) ->
    {error, {invalid_isolation_class, Isolation}};
classify_canonical(Profile, _Isolation) ->
    {error, {unsupported_execution_profile, Profile}}.
