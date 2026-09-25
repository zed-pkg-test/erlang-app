-module(bmscl_execution_policy).

-export([authority/1, required_backend/1, admit_worker/2]).

-spec required_backend(map()) -> bare_process | firecracker | {error, term()}.
required_backend(Target) ->
    case bmscl_execution_boundary:classify(Target) of
        local_bare_process -> bare_process;
        firecracker -> firecracker;
        {error, _} = Error -> Error
    end.

-spec admit_worker(map(), term()) -> ok | {error, term()}.
admit_worker(Target, WorkerBackend0) ->
    case {required_backend(Target), normalize_backend(WorkerBackend0)} of
        {{error, _} = Error, _} ->
            Error;
        {_, {error, _} = Error} ->
            Error;
        {Backend, Backend} ->
            ok;
        {Required, Actual} ->
            {error, {execution_backend_mismatch, Required, Actual}}
    end.

-spec authority(map()) -> {ok, map()} | {error, term()}.
authority(Target) when is_map(Target) ->
    case bmscl_faas_profile:profile(Target) of
        undefined ->
            {ok, #{
                backend => bare_process,
                tenant_isolation => shared_host_restricted_process,
                beam_process_spawn => denied,
                os_process_spawn => denied,
                filesystem => denied,
                persistent_storage => capability_only,
                network => capability_only,
                native_code => denied
            }};
        phoenix_v1 ->
            {ok, #{
                backend => firecracker,
                tenant_isolation => single_tenant_microvm,
                beam_process_spawn => allowed,
                os_process_spawn => denied,
                filesystem => #{
                    release => read_only,
                    tmp => writable_quota,
                    persistent => capability_only
                },
                persistent_storage => capability_only,
                network => capability_only,
                native_code => denied
            }};
        durable_actor_v1 ->
            {ok, #{
                backend => firecracker,
                tenant_isolation => single_tenant_microvm,
                beam_process_spawn => platform_managed,
                os_process_spawn => denied,
                filesystem => #{
                    release => read_only,
                    tmp => writable_quota,
                    persistent => capability_only
                },
                persistent_storage => capability_only,
                network => capability_only,
                native_code => denied
            }};
        Profile ->
            {error, {unsupported_execution_profile, Profile}}
    end;
authority(_) ->
    {error, invalid_route_target}.

normalize_backend(bare_process) -> bare_process;
normalize_backend(firecracker) -> firecracker;
normalize_backend(<<"bare_process">>) -> bare_process;
normalize_backend(<<"firecracker">>) -> firecracker;
normalize_backend(Value) when is_list(Value) ->
    normalize_backend(unicode:characters_to_binary(Value));
normalize_backend(Value) ->
    {error, {invalid_execution_backend, Value}}.
