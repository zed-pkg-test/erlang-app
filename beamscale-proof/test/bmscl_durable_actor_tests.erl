-module(bmscl_durable_actor_tests).

-include_lib("eunit/include/eunit.hrl").

stable_placement_test() ->
    Target = target(),
    {ok, A} = bmscl_durable_shard:placement(
                Target, <<"tenant-a">>, <<"chat">>, <<"room-42">>),
    {ok, B} = bmscl_durable_shard:placement(
                Target, <<"tenant-a">>, <<"chat">>, <<"room-42">>),
    ?assertEqual(maps:get(virtual_shard, A), maps:get(virtual_shard, B)),
    ?assertEqual(maps:get(actor_key, A), maps:get(actor_key, B)),
    ?assert(maps:get(virtual_shard, A) < 4096).

actor_key_never_mixes_tenants_test() ->
    Target = target(),
    {ok, A} = bmscl_durable_shard:placement(
                Target, <<"tenant-a">>, <<"chat">>, <<"same-object">>),
    {ok, B} = bmscl_durable_shard:placement(
                Target, <<"tenant-b">>, <<"chat">>, <<"same-object">>),
    ?assertNotEqual(maps:get(actor_key, A), maps:get(actor_key, B)).

actor_serializes_turn_tokens_test() ->
    Target = target(),
    {ok, A} = bmscl_durable_shard:placement(
                Target, <<"tenant-a">>, <<"chat">>, <<"room-a">>),
    {ok, Pid} = bmscl_durable_actor:start(A, 7),
    try
        {ok, T1} = bmscl_durable_actor:admit_turn(Pid, A),
        {ok, T2} = bmscl_durable_actor:admit_turn(Pid, A),
        ?assertEqual(7, maps:get(epoch, T1)),
        ?assertEqual(1, maps:get(sequence, T1)),
        ?assertEqual(2, maps:get(sequence, T2))
    after
        gen_server:stop(Pid)
    end.

actor_rejects_other_tenant_test() ->
    Target = target(),
    {ok, A} = bmscl_durable_shard:placement(
                Target, <<"tenant-a">>, <<"chat">>, <<"room">>),
    {ok, B} = bmscl_durable_shard:placement(
                Target, <<"tenant-b">>, <<"chat">>, <<"room">>),
    {ok, Pid} = bmscl_durable_actor:start(A, 1),
    try
        ?assertEqual(
           {error, tenant_or_actor_mismatch},
           bmscl_durable_actor:admit_turn(Pid, B))
    after
        gen_server:stop(Pid)
    end.

target() ->
    #{
        execution_class => durable_actor,
        experimental_profile => durable_actor_v1,
        protocol => http,
        namespace => <<"rooms">>,
        virtual_shards => 4096,
        shards_per_actor => 64,
        deployment_id => <<"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">>
    }.
