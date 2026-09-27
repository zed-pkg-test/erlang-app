-module(bmscl_microvm_nonce_registry).
-behaviour(gen_server).

-export([start_link/0, epoch/0, consume/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_MAX_ENTRIES, 65536).
-define(PRUNE_EVERY, 256).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

epoch() ->
    call(epoch).

consume(Nonce, Epoch, ExpiresAt) ->
    call({consume, Nonce, Epoch, ExpiresAt}).

call(Request) ->
    case whereis(?MODULE) of
        undefined -> {error, microvm_nonce_registry_unavailable};
        _ -> gen_server:call(?MODULE, Request)
    end.

init([]) ->
    MaxEntries = application:get_env(
                   bmscl_supervisor, microvm_nonce_cache_max_entries,
                   ?DEFAULT_MAX_ENTRIES),
    case is_integer(MaxEntries) andalso MaxEntries > 0 of
        true ->
            {ok, #{epoch => crypto:strong_rand_bytes(16),
                   seen => #{},
                   operations => 0,
                   max_entries => MaxEntries}};
        false ->
            {stop, invalid_microvm_nonce_cache_max_entries}
    end.

handle_call(epoch, _From, State) ->
    {reply, {ok, maps:get(epoch, State)}, State};
handle_call({consume, Nonce, Epoch, ExpiresAt}, _From, State0) ->
    ReplyState = consume_nonce(Nonce, Epoch, ExpiresAt, State0),
    case ReplyState of
        {Reply, State1} -> {reply, Reply, State1}
    end;
handle_call(_, _From, State) ->
    {reply, {error, invalid_microvm_nonce_registry_request}, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

consume_nonce(Nonce, Epoch, ExpiresAt, State0)
  when is_binary(Nonce), byte_size(Nonce) =:= 16,
       is_binary(Epoch), byte_size(Epoch) =:= 16,
       is_integer(ExpiresAt) ->
    CurrentEpoch = maps:get(epoch, State0),
    case Epoch =:= CurrentEpoch of
        false ->
            {{error, microvm_nonce_epoch_mismatch}, State0};
        true ->
            Now = erlang:system_time(second),
            case ExpiresAt < Now of
                true ->
                    {{error, microvm_contract_expired}, State0};
                false ->
                    State1 = maybe_prune(State0, Now),
                    Seen0 = maps:get(seen, State1),
                    case maps:is_key(Nonce, Seen0) of
                        true ->
                            {{error, microvm_contract_replayed}, State1};
                        false ->
                            MaxEntries = maps:get(max_entries, State1),
                            case ensure_capacity(State1, Now, MaxEntries) of
                                {error, State2} ->
                                    {{error, microvm_nonce_cache_full}, State2};
                                {ok, State2} ->
                                    Seen1 = maps:put(
                                              Nonce, ExpiresAt,
                                              maps:get(seen, State2)),
                                    State3 = State2#{
                                        seen => Seen1,
                                        operations => maps:get(operations, State2) + 1
                                    },
                                    {ok, State3}
                            end
                    end
            end
    end;
consume_nonce(_, _, _, State) ->
    {{error, invalid_microvm_nonce_claim}, State}.

maybe_prune(State, Now) ->
    case maps:get(operations, State) rem ?PRUNE_EVERY of
        0 -> prune(State, Now);
        _ -> State
    end.

ensure_capacity(State, Now, MaxEntries) ->
    case map_size(maps:get(seen, State)) < MaxEntries of
        true -> {ok, State};
        false ->
            State1 = prune(State, Now),
            case map_size(maps:get(seen, State1)) < MaxEntries of
                true -> {ok, State1};
                false -> {error, State1}
            end
    end.

prune(State, Now) ->
    Seen0 = maps:get(seen, State),
    Seen1 = maps:filter(
              fun(_Nonce, ExpiresAt) -> ExpiresAt >= Now end,
              Seen0),
    State#{seen => Seen1}.
