-module(bmscl_execution_policy_tests).

-include_lib("eunit/include/eunit.hrl").

standard_faas_authority_is_minimal_test() ->
    {ok, Policy} = bmscl_execution_policy:authority(#{}),
    ?assertEqual(bare_process, maps:get(backend, Policy)),
    ?assertEqual(denied, maps:get(beam_process_spawn, Policy)),
    ?assertEqual(denied, maps:get(os_process_spawn, Policy)),
    ?assertEqual(denied, maps:get(filesystem, Policy)),
    ?assertEqual(denied, maps:get(native_code, Policy)).

phoenix_authority_is_microvm_scoped_test() ->
    {ok, Policy} = bmscl_execution_policy:authority(#{
        experimental_profile => phoenix_v1,
        isolation_class => firecracker
    }),
    ?assertEqual(firecracker, maps:get(backend, Policy)),
    ?assertEqual(single_tenant_microvm, maps:get(tenant_isolation, Policy)),
    ?assertEqual(allowed, maps:get(beam_process_spawn, Policy)),
    ?assertEqual(denied, maps:get(os_process_spawn, Policy)),
    Fs = maps:get(filesystem, Policy),
    ?assertEqual(read_only, maps:get(release, Fs)),
    ?assertEqual(writable_quota, maps:get(tmp, Fs)),
    ?assertEqual(capability_only, maps:get(persistent, Fs)).

durable_actor_keeps_spawn_platform_managed_test() ->
    {ok, Policy} = bmscl_execution_policy:authority(#{
        experimental_profile => durable_actor_v1,
        isolation_class => firecracker
    }),
    ?assertEqual(firecracker, maps:get(backend, Policy)),
    ?assertEqual(platform_managed, maps:get(beam_process_spawn, Policy)),
    ?assertEqual(denied, maps:get(os_process_spawn, Policy)).

worker_admission_requires_exact_backend_test() ->
    Phoenix = #{
        experimental_profile => phoenix_v1,
        isolation_class => firecracker
    },
    ?assertEqual(ok, bmscl_execution_policy:admit_worker(Phoenix, firecracker)),
    ?assertEqual(
       {error, {execution_backend_mismatch, firecracker, bare_process}},
       bmscl_execution_policy:admit_worker(Phoenix, bare_process)),
    ?assertEqual(
       ok,
       bmscl_execution_policy:admit_worker(#{}, <<"bare_process">>)).
