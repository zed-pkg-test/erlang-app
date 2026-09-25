-module(bmscl_microvm_contract_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"0123456789abcdef0123456789abcdef">>).

issue_and_verify_test() ->
    with_secret(fun() ->
        Target = phoenix_target(),
        {ok, Contract} =
            bmscl_microvm_contract:issue(
              invoke_async, <<"tenant-a">>, Target),
        {ok, Claims} =
            bmscl_microvm_contract:verify(
              Contract, invoke_async, <<"tenant-a">>),
        ?assertEqual(firecracker, maps:get(backend, Claims)),
        ?assertEqual(phoenix_v1, maps:get(experimental_profile, Claims)),
        ?assertEqual(<<"dep-1">>, maps:get(deployment_id, Claims)),
        Authority = maps:get(authority, Claims),
        ?assertEqual(single_tenant_microvm,
                     maps:get(tenant_isolation, Authority)),
        ?assertEqual(allowed, maps:get(beam_process_spawn, Authority)),
        ?assertEqual(denied, maps:get(os_process_spawn, Authority))
    end).

tenant_mismatch_is_rejected_test() ->
    with_secret(fun() ->
        {ok, Contract} =
            bmscl_microvm_contract:issue(
              invoke_async, <<"tenant-a">>, phoenix_target()),
        ?assertEqual(
           {error, microvm_tenant_mismatch},
           bmscl_microvm_contract:verify(
             Contract, invoke_async, <<"tenant-b">>))
    end).

operation_mismatch_is_rejected_test() ->
    with_secret(fun() ->
        {ok, Contract} =
            bmscl_microvm_contract:issue(
              invoke_async, <<"tenant-a">>, phoenix_target()),
        ?assertEqual(
           {error, microvm_operation_mismatch},
           bmscl_microvm_contract:verify(
             Contract, register_connection, <<"tenant-a">>))
    end).

tampering_is_rejected_test() ->
    with_secret(fun() ->
        {ok, Contract0} =
            bmscl_microvm_contract:issue(
              invoke_async, <<"tenant-a">>, phoenix_target()),
        Claims0 = maps:get(claims, Contract0),
        Contract = Contract0#{
            claims => Claims0#{tenant_id => <<"tenant-b">>}
        },
        ?assertEqual(
           {error, invalid_microvm_contract_signature},
           bmscl_microvm_contract:verify(
             Contract, invoke_async, <<"tenant-b">>))
    end).

worker_admission_checks_signed_tenant_test() ->
    with_secret(fun() ->
        Target0 = phoenix_target(),
        {ok, Contract} =
            bmscl_microvm_contract:issue(
              invoke_async, <<"tenant-a">>, Target0),
        Target = Target0#{microvm_contract => Contract},
        ?assertMatch(
           {ok, _},
           bmscl_execution_policy:admit_microvm(
             Target, invoke_async, <<"tenant-a">>)),
        ?assertEqual(
           {error, microvm_tenant_mismatch},
           bmscl_execution_policy:admit_microvm(
             Target, invoke_async, <<"tenant-b">>))
    end).

missing_secret_fails_closed_test() ->
    Previous = application:get_env(bmscl_supervisor, microvm_contract_secret),
    application:unset_env(bmscl_supervisor, microvm_contract_secret),
    try
        ?assertEqual(
           {error, microvm_contract_secret_unavailable},
           bmscl_microvm_contract:issue(
             invoke_async, <<"tenant-a">>, phoenix_target()))
    after
        restore(microvm_contract_secret, Previous)
    end.

tenant_context_required_test() ->
    ?assertEqual(
       {error, microvm_tenant_required},
       bmscl_microvm_contract:tenant_from_context(#{})),
    ?assertEqual(
       {ok, <<"tenant-a">>},
       bmscl_microvm_contract:tenant_from_context(
         #{<<"tenant_id">> => <<"tenant-a">>})).

phoenix_target() ->
    #{deployment_id => <<"dep-1">>,
      execution_class => request,
      experimental_profile => phoenix_v1,
      protocol => http,
      isolation_class => firecracker}.

with_secret(Fun) ->
    Previous = application:get_env(bmscl_supervisor, microvm_contract_secret),
    application:set_env(bmscl_supervisor, microvm_contract_secret, ?SECRET),
    try Fun()
    after restore(microvm_contract_secret, Previous)
    end.

restore(Key, undefined) -> application:unset_env(bmscl_supervisor, Key);
restore(Key, {ok, Value}) -> application:set_env(bmscl_supervisor, Key, Value).
