-module(bmscl_experimental_route_tests).

-include_lib("eunit/include/eunit.hrl").

legacy_route_shape_is_preserved_test() ->
    {ok, 1, Routes} = bmscl_route_manifest:from_map(manifest(target(#{}))),
    Target = maps:get({<<"GET">>, <<"/legacy">>}, Routes),
    ?assertEqual(false, maps:is_key(execution_class, Target)),
    ?assertEqual(false, maps:is_key(protocol, Target)).

phoenix_connection_metadata_is_compiled_test() ->
    Extra = #{
        <<"experimental_profile">> => <<"phoenix_v1">>,
        <<"execution_class">> => <<"connection">>,
        <<"protocol">> => <<"websocket">>,
        <<"drain_timeout_ms">> => 45000
    },
    {ok, 1, Routes} = bmscl_route_manifest:from_map(manifest(target(Extra))),
    Target = maps:get({<<"GET">>, <<"/legacy">>}, Routes),
    ?assertEqual(phoenix_v1, maps:get(experimental_profile, Target)),
    ?assertEqual(connection, maps:get(execution_class, Target)),
    ?assertEqual(websocket, maps:get(protocol, Target)),
    ?assertEqual(45000, maps:get(drain_timeout_ms, Target)).

durable_actor_metadata_is_compiled_test() ->
    Extra = #{
        <<"experimental_profile">> => <<"durable_actor_v1">>,
        <<"execution_class">> => <<"durable_actor">>,
        <<"protocol">> => <<"http">>,
        <<"namespace">> => <<"rooms">>,
        <<"virtual_shards">> => 1024,
        <<"shards_per_actor">> => 32
    },
    {ok, 1, Routes} = bmscl_route_manifest:from_map(manifest(target(Extra))),
    Target = maps:get({<<"GET">>, <<"/legacy">>}, Routes),
    ?assertEqual(durable_actor_v1, maps:get(experimental_profile, Target)),
    ?assertEqual(durable_actor, maps:get(execution_class, Target)),
    ?assertEqual(<<"rooms">>, maps:get(namespace, Target)),
    ?assertEqual(1024, maps:get(virtual_shards, Target)),
    ?assertEqual(32, maps:get(shards_per_actor, Target)).

manifest(Target) ->
    #{
        <<"schema_version">> => <<"ores.routes.v1">>,
        <<"routing_version">> => 1,
        <<"routes">> => [#{
            <<"route_id">> => <<"proof">>,
            <<"method">> => <<"GET">>,
            <<"path">> => <<"/legacy">>,
            <<"target">> => Target
        }]
    }.

target(Extra) ->
    maps:merge(#{
        <<"function_id">> => <<"proof">>,
        <<"deployment_id">> => <<"generation-proof">>,
        <<"artifact_digest">> =>
            <<"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>,
        <<"runtime">> => #{
            <<"kind">> => <<"beam">>,
            <<"entrypoint">> => <<"worker:handle/2">>
        }
    }, Extra).
