-module(bmscl_microvm_nonce_registry_tests).

-include_lib("eunit/include/eunit.hrl").

replay_and_capacity_fail_closed_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, microvm_nonce_cache_max_entries),
    application:set_env(
      bmscl_supervisor, microvm_nonce_cache_max_entries, 1),
    stop_existing_registry(),
    {ok, _} = bmscl_microvm_nonce_registry:start_link(),
    try
        {ok, Epoch} = bmscl_microvm_nonce_registry:epoch(),
        ExpiresAt = erlang:system_time(second) + 30,
        NonceA = <<0:128>>,
        NonceB = <<1:128>>,
        ?assertEqual(
           ok,
           bmscl_microvm_nonce_registry:consume(
             NonceA, Epoch, ExpiresAt)),
        ?assertEqual(
           {error, microvm_contract_replayed},
           bmscl_microvm_nonce_registry:consume(
             NonceA, Epoch, ExpiresAt)),
        ?assertEqual(
           {error, microvm_nonce_cache_full},
           bmscl_microvm_nonce_registry:consume(
             NonceB, Epoch, ExpiresAt))
    after
        stop_existing_registry(),
        restore(microvm_nonce_cache_max_entries, Previous)
    end.

wrong_epoch_and_malformed_claims_fail_closed_test() ->
    Previous = application:get_env(
                 bmscl_supervisor, microvm_nonce_cache_max_entries),
    application:set_env(
      bmscl_supervisor, microvm_nonce_cache_max_entries, 16),
    stop_existing_registry(),
    {ok, _} = bmscl_microvm_nonce_registry:start_link(),
    try
        {ok, Epoch} = bmscl_microvm_nonce_registry:epoch(),
        ExpiresAt = erlang:system_time(second) + 30,
        ?assertEqual(
           {error, microvm_nonce_epoch_mismatch},
           bmscl_microvm_nonce_registry:consume(
             <<0:128>>, <<9:128>>, ExpiresAt)),
        ?assertEqual(
           {error, invalid_microvm_nonce_claim},
           bmscl_microvm_nonce_registry:consume(
             <<1, 2, 3>>, Epoch, ExpiresAt))
    after
        stop_existing_registry(),
        restore(microvm_nonce_cache_max_entries, Previous)
    end.

stop_existing_registry() ->
    case whereis(bmscl_microvm_nonce_registry) of
        undefined -> ok;
        _ -> gen_server:stop(bmscl_microvm_nonce_registry)
    end.

restore(Key, undefined) -> application:unset_env(bmscl_supervisor, Key);
restore(Key, {ok, Value}) -> application:set_env(bmscl_supervisor, Key, Value).
