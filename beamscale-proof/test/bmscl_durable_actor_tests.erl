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


placement_rejects_handcrafted_invalid_route_target_test() ->
    BadLayout = (target())#{virtual_shards => 1, shards_per_actor => 1},
    ?assertMatch(
       {error, {invalid_durable_target, _}},
       bmscl_durable_shard:placement(
         BadLayout, <<"tenant-a">>, <<"chat">>, <<"room">>)),
    BadNamespace = (target())#{namespace => <<"rooms/escape">>},
    ?assertMatch(
       {error, {invalid_durable_target, _}},
       bmscl_durable_shard:placement(
         BadNamespace, <<"tenant-a">>, <<"chat">>, <<"room">>)),
    BadIsolation = (target())#{isolation_class => bare_process},
    ?assertMatch(
       {error, {invalid_durable_target, _}},
       bmscl_durable_shard:placement(
         BadIsolation, <<"tenant-a">>, <<"chat">>, <<"room">>)).

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

actor_rejects_forged_same_actor_key_metadata_test() ->
    Target = target(),
    {ok, A} = bmscl_durable_shard:placement(
                Target, <<"tenant-a">>, <<"chat">>, <<"room">>),
    {ok, Pid} = bmscl_durable_actor:start(A, 1),
    try
        ForgedApp = A#{application_id => <<"other-app">>},
        ForgedNamespace = A#{namespace => <<"other-namespace">>},
        ForgedDeployment = A#{
            deployment_id =>
                <<"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb">>
        },
        ?assertEqual(
           {error, tenant_or_actor_mismatch},
           bmscl_durable_actor:admit_turn(Pid, ForgedApp)),
        ?assertEqual(
           {error, tenant_or_actor_mismatch},
           bmscl_durable_actor:admit_turn(Pid, ForgedNamespace)),
        ?assertEqual(
           {error, tenant_or_actor_mismatch},
           bmscl_durable_actor:admit_turn(Pid, ForgedDeployment))
    after
        gen_server:stop(Pid)
    end.

actor_rejects_virtual_shard_outside_bucket_test() ->
    Target = target(),
    {ok, A} = bmscl_durable_shard:placement(
                Target, <<"tenant-a">>, <<"chat">>, <<"room">>),
    {ok, Pid} = bmscl_durable_actor:start(A, 1),
    try
        Bucket = maps:get(actor_bucket, A),
        ShardsPerActor = maps:get(shards_per_actor, A),
        OtherShard = ((Bucket + 1) * ShardsPerActor) rem maps:get(virtual_shards, A),
        Forged = A#{virtual_shard => OtherShard},
        ?assertEqual(
           {error, tenant_or_actor_mismatch},
           bmscl_durable_actor:admit_turn(Pid, Forged))
    after
        gen_server:stop(Pid)
    end.

state_commit_is_fenced_after_ownership_transfer_test() ->
    bmscl_durable_test_store:reset(),
    Previous = application:get_env(bmscl_supervisor, durable_store_module),
    application:set_env(
      bmscl_supervisor, durable_store_module, bmscl_durable_test_store),
    Target = target(),
    {ok, Placement} = bmscl_durable_shard:placement(
                        Target, <<"tenant-a">>, <<"chat">>, <<"room-fenced">>),
    try
        {ok, OldPid} = bmscl_durable_actor:start(Placement),
        try
            {ok, OldTurn} = bmscl_durable_actor:admit_turn(OldPid, Placement),
            ?assertEqual(1, maps:get(owner_epoch, OldTurn)),
            ?assertEqual(
               {ok, not_found},
               bmscl_durable_actor:load_state(OldPid, Placement, OldTurn)),
            ?assertEqual(
               {ok, 1},
               bmscl_durable_actor:commit_state(
                 OldPid, Placement, OldTurn, 0, <<"v1">>)),
            ?assertEqual(
               {ok, #{version => 1, state => <<"v1">>}},
               bmscl_durable_actor:load_state(OldPid, Placement, OldTurn)),

            %% A different owner is assigned while the old actor is still alive.
            %% The old process still has epoch 1 cached, but the durable store is
            %% now authoritative at epoch 2 and must reject the stale writer.
            {ok, 2} = bmscl_durable_test_store:claim_owner(owner_scope(Placement)),
            ?assertEqual(
               {error, {stale_owner_epoch, 2}},
               bmscl_durable_actor:commit_state(
                 OldPid, Placement, OldTurn, 1, <<"stale">>))
        after
            gen_server:stop(OldPid)
        end,

        %% A replacement actor claims the next authoritative epoch and resumes
        %% from the already committed object version.
        {ok, NewPid} = bmscl_durable_actor:start(Placement),
        try
            {ok, NewTurn} = bmscl_durable_actor:admit_turn(NewPid, Placement),
            ?assertEqual(3, maps:get(owner_epoch, NewTurn)),
            ?assertEqual(
               {ok, #{version => 1, state => <<"v1">>}},
               bmscl_durable_actor:load_state(NewPid, Placement, NewTurn)),
            ?assertEqual(
               {ok, 2},
               bmscl_durable_actor:commit_state(
                 NewPid, Placement, NewTurn, 1, <<"v2">>)),
            ?assertEqual(
               {ok, #{version => 2, state => <<"v2">>}},
               bmscl_durable_actor:load_state(NewPid, Placement, NewTurn))
        after
            gen_server:stop(NewPid)
        end
    after
        restore_env(durable_store_module, Previous),
        bmscl_durable_test_store:reset()
    end.

older_turn_token_cannot_commit_after_newer_turn_test() ->
    bmscl_durable_test_store:reset(),
    Previous = application:get_env(bmscl_supervisor, durable_store_module),
    application:set_env(
      bmscl_supervisor, durable_store_module, bmscl_durable_test_store),
    Target = target(),
    {ok, Placement} = bmscl_durable_shard:placement(
                        Target, <<"tenant-a">>, <<"chat">>, <<"room-order">>),
    try
        {ok, Pid} = bmscl_durable_actor:start(Placement),
        try
            {ok, T1} = bmscl_durable_actor:admit_turn(Pid, Placement),
            {ok, T2} = bmscl_durable_actor:admit_turn(Pid, Placement),
            ?assertEqual(
               {error, stale_or_invalid_turn_token},
               bmscl_durable_actor:commit_state(
                 Pid, Placement, T1, 0, <<"late">>)),
            ?assertEqual(
               {ok, 1},
               bmscl_durable_actor:commit_state(
                 Pid, Placement, T2, 0, <<"current">>))
        after
            gen_server:stop(Pid)
        end
    after
        restore_env(durable_store_module, Previous),
        bmscl_durable_test_store:reset()
    end.

forged_turn_token_cannot_load_or_commit_test() ->
    bmscl_durable_test_store:reset(),
    Previous = application:get_env(bmscl_supervisor, durable_store_module),
    application:set_env(
      bmscl_supervisor, durable_store_module, bmscl_durable_test_store),
    Target = target(),
    {ok, Placement} = bmscl_durable_shard:placement(
                        Target, <<"tenant-a">>, <<"chat">>, <<"room-forged">>),
    try
        {ok, Pid} = bmscl_durable_actor:start(Placement),
        try
            {ok, Turn} = bmscl_durable_actor:admit_turn(Pid, Placement),
            Forged = Turn#{owner_epoch => maps:get(owner_epoch, Turn) + 1},
            ?assertEqual(
               {error, stale_or_invalid_turn_token},
               bmscl_durable_actor:load_state(Pid, Placement, Forged)),
            ?assertEqual(
               {error, stale_or_invalid_turn_token},
               bmscl_durable_actor:commit_state(
                 Pid, Placement, Forged, 0, <<"forged">>))
        after
            gen_server:stop(Pid)
        end
    after
        restore_env(durable_store_module, Previous),
        bmscl_durable_test_store:reset()
    end.

owner_scope(Placement) ->
    #{
        tenant_id => maps:get(tenant_id, Placement),
        application_id => maps:get(application_id, Placement),
        namespace => maps:get(namespace, Placement),
        virtual_shard => maps:get(virtual_shard, Placement)
    }.

restore_env(Key, {ok, Value}) ->
    application:set_env(bmscl_supervisor, Key, Value);
restore_env(Key, undefined) ->
    application:unset_env(bmscl_supervisor, Key).

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
