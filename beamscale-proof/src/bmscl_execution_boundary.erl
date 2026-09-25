-module(bmscl_execution_boundary).

-export([classify/1]).

-spec classify(map()) -> local_bare_process | firecracker | {error, term()}.
classify(Target) when is_map(Target) ->
    case maps:get(isolation_class, Target, bare_process) of
        bare_process -> local_bare_process;
        firecracker -> firecracker;
        Value -> {error, {invalid_isolation_class, Value}}
    end;
classify(_) ->
    {error, invalid_route_target}.
