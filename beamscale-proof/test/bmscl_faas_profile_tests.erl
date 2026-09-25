-module(bmscl_faas_profile_tests).

-include_lib("eunit/include/eunit.hrl").

default_lambda_profile_test() ->
    ?assertEqual(
       {ok, #{}},
       bmscl_faas_profile:normalize(#{})).

phoenix_request_is_still_faas_request_test() ->
    ?assertEqual(
       {ok, #{execution_class => request,
              experimental_profile => phoenix_v1,
              protocol => http}},
       bmscl_faas_profile:normalize(#{
           <<"experimental_profile">> => <<"phoenix_v1">>,
           <<"execution_class">> => <<"request">>,
           <<"protocol">> => <<"http">>
       })).

phoenix_connection_profile_test() ->
    {ok, Profile} = bmscl_faas_profile:normalize(#{
        execution_class => connection,
        experimental_profile => phoenix_v1,
        protocol => websocket
    }),
    ?assertEqual(connection, maps:get(execution_class, Profile)),
    ?assertEqual(30000, maps:get(drain_timeout_ms, Profile)).

connection_requires_experimental_profile_test() ->
    ?assertEqual(
       {error, {experimental_profile_required, connection}},
       bmscl_faas_profile:normalize(#{
           execution_class => connection,
           protocol => websocket
       })).

durable_actor_layout_is_normalized_test() ->
    {ok, Profile} = bmscl_faas_profile:normalize(#{
        execution_class => durable_actor,
        experimental_profile => durable_actor_v1,
        namespace => <<"rooms">>
    }),
    ?assertEqual(4096, maps:get(virtual_shards, Profile)),
    ?assertEqual(64, maps:get(shards_per_actor, Profile)).

experimental_profile_gate_test() ->
    Previous = application:get_env(bmscl_supervisor, experimental_faas_profiles),
    try
        application:set_env(bmscl_supervisor, experimental_faas_profiles, []),
        ?assertEqual(
           {error, {experimental_profile_disabled, phoenix_v1}},
           bmscl_faas_profile:ensure_enabled(#{experimental_profile => phoenix_v1})),
        application:set_env(bmscl_supervisor, experimental_faas_profiles, [phoenix_v1]),
        ?assertEqual(
           ok,
           bmscl_faas_profile:ensure_enabled(#{experimental_profile => phoenix_v1}))
    after
        restore_env(Previous)
    end.

restore_env(undefined) ->
    application:unset_env(bmscl_supervisor, experimental_faas_profiles);
restore_env({ok, Value}) ->
    application:set_env(bmscl_supervisor, experimental_faas_profiles, Value).
