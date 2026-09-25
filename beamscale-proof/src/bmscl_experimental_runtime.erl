-module(bmscl_experimental_runtime).

-export([invoke_async/3, register_connection/3, locate_durable_actor/4]).

invoke_async(Target, Request, Context) ->
    call(invoke_async, Target, [Request, Context]).

register_connection(Target, TransportPid, Context) ->
    call(register_connection, Target, [TransportPid, Context]).

locate_durable_actor(Target, TenantId, ApplicationId, ObjectKey) ->
    call(locate_durable_actor, Target, [TenantId, ApplicationId, ObjectKey]).

call(Operation, Target, RestArgs) ->
    case bmscl_execution_boundary:classify(Target) of
        firecracker ->
            dispatch(Operation, [Target | RestArgs]);
        local_bare_process ->
            {error, {firecracker_runtime_required,
                     Operation, local_bare_process}};
        {error, Reason} ->
            {error, Reason}
    end.

dispatch(Operation, Args) ->
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
