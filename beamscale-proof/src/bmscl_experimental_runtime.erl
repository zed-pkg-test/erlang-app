-module(bmscl_experimental_runtime).

-export([invoke_async/3, register_connection/3, locate_durable_actor/4]).

invoke_async(Target, Request, Context) ->
    case bmscl_microvm_contract:tenant_from_context(Context) of
        {ok, TenantId} ->
            call_checked(request, invoke_async, Target, TenantId, [Request, Context]);
        {error, Reason} -> {error, Reason}
    end.

register_connection(Target, TransportPid, Context) ->
    case bmscl_microvm_contract:tenant_from_context(Context) of
        {ok, TenantId} ->
            call_checked(
              connection, register_connection, Target, TenantId,
              [TransportPid, Context]);
        {error, Reason} -> {error, Reason}
    end.

locate_durable_actor(Target, TenantId, ApplicationId, ObjectKey) ->
    call_checked(
      durable_actor, locate_durable_actor, Target, TenantId,
      [TenantId, ApplicationId, ObjectKey]).

call_checked(ExpectedClass, Operation, Target, TenantId, TailArgs) ->
    case validate_target(ExpectedClass, Target) of
        {ok, CanonicalTarget0} ->
            case bmscl_microvm_contract:issue(
                   Operation, TenantId, CanonicalTarget0) of
                {ok, Contract} ->
                    CanonicalTarget =
                        CanonicalTarget0#{microvm_contract => Contract},
                    call(Operation, [CanonicalTarget | TailArgs]);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

validate_target(ExpectedClass, Target) when is_map(Target) ->
    case bmscl_faas_profile:normalize(Target) of
        {error, Reason} ->
            {error, {invalid_experimental_target, operation_class(ExpectedClass), Reason}};
        {ok, ProfileFields} ->
            case bmscl_faas_profile:ensure_enabled(ProfileFields) of
                {error, Reason} ->
                    {error, Reason};
                ok ->
                    Class = bmscl_faas_profile:execution_class(ProfileFields),
                    case {Class =:= ExpectedClass,
                          bmscl_execution_boundary:classify(ProfileFields)} of
                        {false, _} ->
                            {error, {unexpected_experimental_execution_class,
                                     ExpectedClass, Class}};
                        {true, firecracker} ->
                            CanonicalTarget = maps:merge(Target, ProfileFields),
                            validate_artifact_contract(CanonicalTarget);
                        {true, Boundary} ->
                            {error, {experimental_target_requires_firecracker,
                                     ExpectedClass, Boundary}}
                    end
            end
    end;
validate_target(ExpectedClass, _) ->
    {error, {invalid_experimental_target, operation_class(ExpectedClass),
             invalid_route_target}}.

operation_class(request) -> request;
operation_class(connection) -> connection;
operation_class(durable_actor) -> durable_actor.

call(Operation, Args) ->
    case application:get_env(
           bmscl_supervisor, experimental_runtime_dispatcher_module, undefined) of
        undefined ->
            {error, {firecracker_runtime_dispatcher_unavailable, Operation}};
        Module when is_atom(Module) ->
            Arity = length(Args),
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    case erlang:function_exported(Module, Operation, Arity) of
                        false ->
                            {error, {invalid_firecracker_runtime_dispatcher,
                                     Module, Operation, Arity}};
                        true ->
                            try apply(Module, Operation, Args) of
                                Result -> Result
                            catch
                                Class:Reason ->
                                    {error, {firecracker_runtime_dispatch_failed,
                                             Operation, Class, Reason}}
                            end
                    end;
                {error, Reason} ->
                    {error, {invalid_firecracker_runtime_dispatcher,
                             Module, Reason}}
            end;
        Value ->
            {error, {invalid_firecracker_runtime_dispatcher, Value}}
    end.

-define(DURABLE_ARTIFACT_PROFILE, <<"bmscl-hosted-gleam-durable-actor-v1">>).

validate_artifact_contract(Target) ->
    case bmscl_faas_profile:profile(Target) of
        durable_actor_v1 ->
            validate_durable_artifact_contract(Target);
        _ ->
            {ok, Target}
    end.

validate_durable_artifact_contract(Target) ->
    case maps:find(deployment_id, Target) of
        error ->
            {error, durable_deployment_id_required};
        {ok, DeploymentId} ->
            case bmscl_deployment_manager:pin_deployment(DeploymentId) of
                {error, Reason} ->
                    {error, {durable_deployment_unavailable, Reason}};
                {ok, Pin} ->
                    try durable_pin_matches_target(Pin, Target) of
                        true -> {ok, Target};
                        false -> {error, durable_artifact_contract_mismatch}
                    after
                        _ = bmscl_deployment_manager:release_pin(Pin)
                    end
            end
    end.

durable_pin_matches_target(Pin, Target) ->
    maps:get(profile, Pin, undefined) =:= ?DURABLE_ARTIFACT_PROFILE
    andalso maps:get(deployment_id, Pin, undefined) =:= maps:get(deployment_id, Target, undefined)
    andalso maps:get(durable, Pin, undefined) =:= #{
        namespace => maps:get(namespace, Target, undefined),
        virtual_shards => maps:get(virtual_shards, Target, undefined),
        shards_per_actor => maps:get(shards_per_actor, Target, undefined)
    }.
