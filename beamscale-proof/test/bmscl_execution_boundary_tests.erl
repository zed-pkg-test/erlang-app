-module(bmscl_execution_boundary_tests).

-include_lib("eunit/include/eunit.hrl").

legacy_routes_remain_local_test() ->
    ?assertEqual(local_bare_process,
                 bmscl_execution_boundary:classify(#{deployment_id => <<"dep">>})).

explicit_bare_process_remains_local_test() ->
    ?assertEqual(local_bare_process,
                 bmscl_execution_boundary:classify(#{isolation_class => bare_process})).

firecracker_routes_are_external_test() ->
    ?assertEqual(firecracker,
                 bmscl_execution_boundary:classify(#{isolation_class => firecracker})).

experimental_profile_cannot_claim_bare_process_test() ->
    ?assertEqual(
       {error, {experimental_profile_backend_mismatch,
                phoenix_v1, firecracker, bare_process}},
       bmscl_execution_boundary:classify(#{
           experimental_profile => phoenix_v1,
           isolation_class => bare_process
       })),
    ?assertEqual(
       {error, {experimental_profile_backend_mismatch,
                durable_actor_v1, firecracker, bare_process}},
       bmscl_execution_boundary:classify(#{
           experimental_profile => durable_actor_v1,
           isolation_class => bare_process
       })).

unknown_profile_fails_closed_test() ->
    ?assertEqual(
       {error, {unsupported_execution_profile, unknown_profile}},
       bmscl_execution_boundary:classify(#{
           experimental_profile => unknown_profile,
           isolation_class => firecracker
       })).

invalid_isolation_class_fails_closed_test() ->
    ?assertEqual({error, {invalid_isolation_class, container}},
                 bmscl_execution_boundary:classify(#{
                     experimental_profile => phoenix_v1,
                     isolation_class => container
                 })).
