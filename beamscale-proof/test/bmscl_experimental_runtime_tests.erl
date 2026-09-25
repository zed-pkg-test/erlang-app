-module(bmscl_experimental_runtime_tests).

-include_lib("eunit/include/eunit.hrl").

dispatcher_unavailable_fails_closed_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, experimental_runtime_dispatcher_module),
    application:unset_env(bmscl_supervisor, experimental_runtime_dispatcher_module),
    try
        ?assertEqual(
           {error, {firecracker_runtime_dispatcher_unavailable, invoke_async}},
           bmscl_experimental_runtime:invoke_async(firecracker_target(), req, #{}))
    after
        restore(Previous)
    end.

bare_process_work_cannot_enter_firecracker_dispatcher_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, experimental_runtime_dispatcher_module),
    ok = application:set_env(
           bmscl_supervisor, experimental_runtime_dispatcher_module,
           bmscl_experimental_runtime_test_dispatcher),
    try
        ?assertEqual(
           {error, {firecracker_runtime_required,
                    invoke_async, local_bare_process}},
           bmscl_experimental_runtime:invoke_async(#{}, request, #{}))
    after
        restore(Previous)
    end.

configured_dispatcher_receives_firecracker_work_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, experimental_runtime_dispatcher_module),
    ok = application:set_env(
           bmscl_supervisor, experimental_runtime_dispatcher_module,
           bmscl_experimental_runtime_test_dispatcher),
    try
        Target = firecracker_target(),
        ?assertMatch(
           {ok, {external_invoke, Target, request, #{}}},
           bmscl_experimental_runtime:invoke_async(Target, request, #{})),
        ?assertMatch(
           {ok, {external_connection, Target, _, #{}}},
           bmscl_experimental_runtime:register_connection(Target, self(), #{})),
        ?assertEqual(
           {ok, {external_durable, Target, <<"t">>, <<"a">>, <<"o">>}},
           bmscl_experimental_runtime:locate_durable_actor(
             Target, <<"t">>, <<"a">>, <<"o">>))
    after
        restore(Previous)
    end.

invalid_dispatcher_fails_closed_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, experimental_runtime_dispatcher_module),
    ok = application:set_env(
           bmscl_supervisor, experimental_runtime_dispatcher_module,
           definitely_missing_bmscl_dispatcher),
    try
        ?assertMatch(
           {error, {invalid_firecracker_runtime_dispatcher,
                    definitely_missing_bmscl_dispatcher, _}},
           bmscl_experimental_runtime:invoke_async(
             firecracker_target(), request, #{}))
    after
        restore(Previous)
    end.

profile_backend_mismatch_never_dispatches_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, experimental_runtime_dispatcher_module),
    ok = application:set_env(
           bmscl_supervisor, experimental_runtime_dispatcher_module,
           bmscl_experimental_runtime_test_dispatcher),
    try
        ?assertEqual(
           {error, {experimental_profile_backend_mismatch,
                    phoenix_v1, firecracker, bare_process}},
           bmscl_experimental_runtime:invoke_async(#{
               experimental_profile => phoenix_v1,
               isolation_class => bare_process
           }, request, #{}))
    after
        restore(Previous)
    end.

firecracker_target() ->
    #{experimental_profile => phoenix_v1,
      isolation_class => firecracker}.

restore({ok, Value}) ->
    application:set_env(
      bmscl_supervisor, experimental_runtime_dispatcher_module, Value);
restore(undefined) ->
    application:unset_env(
      bmscl_supervisor, experimental_runtime_dispatcher_module).
