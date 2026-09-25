-module(bmscl_experimental_runtime_tests).

-include_lib("eunit/include/eunit.hrl").

dispatcher_unavailable_fails_closed_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, experimental_runtime_dispatcher_module),
    application:unset_env(bmscl_supervisor, experimental_runtime_dispatcher_module),
    try
        ?assertEqual(
           {error, {firecracker_runtime_dispatcher_unavailable, invoke_async}},
           bmscl_experimental_runtime:invoke_async(#{}, req, #{}))
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
        Target = #{isolation_class => firecracker},
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
           bmscl_experimental_runtime:invoke_async(#{}, request, #{}))
    after
        restore(Previous)
    end.

restore({ok, Value}) ->
    application:set_env(
      bmscl_supervisor, experimental_runtime_dispatcher_module, Value);
restore(undefined) ->
    application:unset_env(
      bmscl_supervisor, experimental_runtime_dispatcher_module).
