-module(bmscl_experimental_runtime_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SECRET, <<"0123456789abcdef0123456789abcdef">>).

dispatcher_unavailable_fails_closed_test() ->
    with_runtime([phoenix_v1], undefined, fun() ->
        ?assertEqual(
           {error, {firecracker_runtime_dispatcher_unavailable, invoke_async}},
           bmscl_experimental_runtime:invoke_async(
             request_target(), req, tenant_ctx()))
    end).

microvm_tenant_is_required_before_dispatch_test() ->
    with_runtime([phoenix_v1], bmscl_experimental_runtime_test_dispatcher, fun() ->
        ?assertEqual(
           {error, microvm_tenant_required},
           bmscl_experimental_runtime:invoke_async(
             request_target(), request, #{}))
    end).

configured_dispatcher_receives_signed_firecracker_work_test() ->
    with_runtime(all, bmscl_experimental_runtime_test_dispatcher, fun() ->
        RequestTarget = request_target(),
        {ok, {external_invoke, RoutedRequestTarget, request, Context}} =
            bmscl_experimental_runtime:invoke_async(
              RequestTarget, request, tenant_ctx()),
        ?assertEqual(tenant_ctx(), Context),
        ?assertMatch(
           {ok, _},
           bmscl_execution_policy:admit_microvm(
             RoutedRequestTarget, invoke_async, <<"tenant-a">>)),

        ConnectionTarget = connection_target(),
        {ok, {external_connection, RoutedConnectionTarget, _Pid, _Context}} =
            bmscl_experimental_runtime:register_connection(
              ConnectionTarget, self(), tenant_ctx()),
        ?assertMatch(
           {ok, _},
           bmscl_execution_policy:admit_microvm(
             RoutedConnectionTarget, register_connection, <<"tenant-a">>)),

        %% Durable dispatch still additionally requires an immutable admitted
        %% deployment contract; a hand-crafted profile alone is not enough.
        ?assertEqual(
           {error, durable_deployment_id_required},
           bmscl_experimental_runtime:locate_durable_actor(
             durable_target(), <<"tenant-a">>, <<"a">>, <<"o">>))
    end).

disabled_durable_profile_never_reaches_dispatcher_test() ->
    with_runtime([], bmscl_experimental_runtime_test_dispatcher, fun() ->
        ?assertEqual(
           {error, {experimental_profile_disabled, durable_actor_v1}},
           bmscl_experimental_runtime:locate_durable_actor(
             durable_target(), <<"tenant-a">>, <<"a">>, <<"o">>))
    end).

invalid_direct_target_fails_before_dispatch_test() ->
    with_runtime(all, bmscl_experimental_runtime_test_dispatcher, fun() ->
        ?assertMatch(
           {error, {invalid_experimental_target, durable_actor, _}},
           bmscl_experimental_runtime:locate_durable_actor(
             #{execution_class => durable_actor,
               experimental_profile => durable_actor_v1,
               protocol => http,
               namespace => <<"rooms/invalid">>,
               isolation_class => firecracker},
             <<"tenant-a">>, <<"a">>, <<"o">>))
    end).

invalid_dispatcher_fails_closed_test() ->
    with_runtime([phoenix_v1], definitely_missing_bmscl_dispatcher, fun() ->
        ?assertMatch(
           {error, {invalid_firecracker_runtime_dispatcher,
                    definitely_missing_bmscl_dispatcher, _}},
           bmscl_experimental_runtime:invoke_async(
             request_target(), request, tenant_ctx()))
    end).

missing_signing_secret_fails_closed_test() ->
    PreviousSecret = application:get_env(
                       bmscl_supervisor, microvm_contract_secret),
    application:unset_env(bmscl_supervisor, microvm_contract_secret),
    try
        PreviousProfiles = application:get_env(
                             bmscl_supervisor, experimental_faas_profiles),
        application:set_env(
          bmscl_supervisor, experimental_faas_profiles, [phoenix_v1]),
        try
            ?assertEqual(
               {error, microvm_contract_secret_unavailable},
               bmscl_experimental_runtime:invoke_async(
                 request_target(), request, tenant_ctx()))
        after
            restore(experimental_faas_profiles, PreviousProfiles)
        end
    after
        restore(microvm_contract_secret, PreviousSecret)
    end.

request_target() ->
    #{execution_class => request,
      experimental_profile => phoenix_v1,
      protocol => http,
      isolation_class => firecracker}.

connection_target() ->
    #{execution_class => connection,
      experimental_profile => phoenix_v1,
      protocol => websocket,
      drain_timeout_ms => 30000,
      isolation_class => firecracker}.

durable_target() ->
    #{execution_class => durable_actor,
      experimental_profile => durable_actor_v1,
      protocol => http,
      namespace => <<"rooms">>,
      virtual_shards => 4096,
      shards_per_actor => 64,
      isolation_class => firecracker}.

tenant_ctx() ->
    #{tenant_id => <<"tenant-a">>}.

with_runtime(Profiles, Dispatcher, Fun) ->
    PreviousDispatcher = application:get_env(
                           bmscl_supervisor, experimental_runtime_dispatcher_module),
    PreviousProfiles = application:get_env(
                         bmscl_supervisor, experimental_faas_profiles),
    PreviousSecret = application:get_env(
                       bmscl_supervisor, microvm_contract_secret),
    case Dispatcher of
        undefined ->
            application:unset_env(
              bmscl_supervisor, experimental_runtime_dispatcher_module);
        _ ->
            application:set_env(
              bmscl_supervisor, experimental_runtime_dispatcher_module, Dispatcher)
    end,
    application:set_env(
      bmscl_supervisor, experimental_faas_profiles, Profiles),
    application:set_env(
      bmscl_supervisor, microvm_contract_secret, ?SECRET),
    try Fun()
    after
        restore(experimental_runtime_dispatcher_module, PreviousDispatcher),
        restore(experimental_faas_profiles, PreviousProfiles),
        restore(microvm_contract_secret, PreviousSecret)
    end.

restore(Key, {ok, Value}) ->
    application:set_env(bmscl_supervisor, Key, Value);
restore(Key, undefined) ->
    application:unset_env(bmscl_supervisor, Key).
