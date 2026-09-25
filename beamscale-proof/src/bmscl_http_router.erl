-module(bmscl_http_router).

-export([resolve/2, invoke/5, invoke_async/4, register_connection/4, locate_durable_actor/5]).

resolve(Method, Path) ->
    bmscl_route_matcher:resolve(Method, Path).

invoke(Method, Path, Request, Context, Timeout) ->
    case invoke_async(Method, Path, Request, Context) of
        {ok, Handle} -> bmscl_router:await(Handle, Timeout);
        Error -> Error
    end.

invoke_async(Method, Path, Request, Context0) ->
    case bmscl_route_matcher:resolve(Method, Path) of
        {ok, Target} ->
            case admit_target(Target) of
                {ok, Backend} ->
                    case bmscl_faas_profile:execution_class(Target) of
                        request ->
                            Context = attach_route_context(Context0, Method, Path, Target),
                            invoke_request(Backend, Target, Request, Context);
                        connection ->
                            {error, connection_route_requires_registration};
                        durable_actor ->
                            {error, durable_actor_route_requires_actor_api}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end;
        Error -> Error
    end.

register_connection(Method, Path, TransportPid, Context0) when is_pid(TransportPid) ->
    case bmscl_route_matcher:resolve(Method, Path) of
        {ok, Target} ->
            case bmscl_faas_profile:execution_class(Target) of
                connection ->
                    case admit_target(Target) of
                        {ok, Backend} ->
                            Context = attach_route_context(Context0, Method, Path, Target),
                            register_connection_backend(
                              Backend, Target, TransportPid, Context);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                Class ->
                    {error, {route_is_not_connection_class, Class}}
            end;
        Error -> Error
    end;
register_connection(_Method, _Path, _TransportPid, _Context) ->
    {error, invalid_transport_pid}.

locate_durable_actor(Method, Path, TenantId, ApplicationId, ObjectKey) ->
    case bmscl_route_matcher:resolve(Method, Path) of
        {ok, Target} ->
            case bmscl_faas_profile:execution_class(Target) of
                durable_actor ->
                    case admit_target(Target) of
                        {ok, Backend} ->
                            locate_durable_backend(
                              Backend, Target, TenantId, ApplicationId, ObjectKey);
                        {error, Reason} ->
                            {error, Reason}
                    end;
                Class ->
                    {error, {route_is_not_durable_actor_class, Class}}
            end;
        Error -> Error
    end.

admit_target(Target) ->
    case bmscl_faas_profile:ensure_enabled(Target) of
        ok ->
            case bmscl_execution_boundary:classify(Target) of
                local_bare_process -> {ok, local_bare_process};
                firecracker -> {ok, firecracker};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

invoke_request(local_bare_process, Target, Request, Context) ->
    DeploymentId = maps:get(deployment_id, Target),
    bmscl_router:invoke_async(DeploymentId, Request, Context);
invoke_request(firecracker, Target, Request, Context) ->
    bmscl_experimental_runtime:invoke_async(Target, Request, Context).

register_connection_backend(local_bare_process, Target, TransportPid, Context) ->
    bmscl_phoenix_connections:register(TransportPid, Target, Context);
register_connection_backend(firecracker, Target, TransportPid, Context) ->
    bmscl_experimental_runtime:register_connection(
      Target, TransportPid, Context).

locate_durable_backend(local_bare_process, Target, TenantId, ApplicationId, ObjectKey) ->
    bmscl_durable_registry:locate(Target, TenantId, ApplicationId, ObjectKey);
locate_durable_backend(firecracker, Target, TenantId, ApplicationId, ObjectKey) ->
    bmscl_experimental_runtime:locate_durable_actor(
      Target, TenantId, ApplicationId, ObjectKey).

attach_route_context(Context0, Method, Path, Target) ->
    Route0 = maps:with(
               [actor_path, source_path, route_id, function_id, artifact_digest,
                entrypoint, path_params, execution_class, experimental_profile,
                protocol, isolation_class, namespace, virtual_shards,
                shards_per_actor, drain_timeout_ms],
               Target),
    Route = Route0#{method => normalize_context_value(Method),
                    path => normalize_context_value(Path),
                    deployment_id => maps:get(deployment_id, Target)},
    case is_map(Context0) of
        true -> Context0#{bmscl_route => Route};
        false -> #{request_context => Context0, bmscl_route => Route}
    end.

normalize_context_value(Value) when is_binary(Value) -> Value;
normalize_context_value(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
normalize_context_value(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
normalize_context_value(Value) -> Value.
