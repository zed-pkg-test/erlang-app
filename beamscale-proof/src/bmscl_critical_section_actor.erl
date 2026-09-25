-module(bmscl_critical_section_actor).
-behaviour(gen_server).

-export([start/1, start/2, acquire/3, renew/4, release/3, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Compatibility/test constructor. Production registry code uses start/2 with
%% an owner epoch allocated by the durable store.
start(RuntimeEpoch) when is_integer(RuntimeEpoch), RuntimeEpoch > 0 ->
    start(RuntimeEpoch, RuntimeEpoch);
start(_) ->
    {error, invalid_runtime_epoch}.

start(RuntimeEpoch, OwnerEpoch)
  when is_integer(RuntimeEpoch), RuntimeEpoch > 0,
       is_integer(OwnerEpoch), OwnerEpoch > 0 ->
    gen_server:start(?MODULE, {RuntimeEpoch, OwnerEpoch}, []);
start(_, _) ->
    {error, invalid_owner_epoch}.

acquire(Pid, Holder, LeaseMs) when is_pid(Pid) ->
    gen_server:call(Pid, {acquire, Holder, LeaseMs});
acquire(_, _, _) ->
    {error, invalid_actor}.

renew(Pid, Holder, Token, LeaseMs) when is_pid(Pid) ->
    gen_server:call(Pid, {renew, Holder, Token, LeaseMs});
renew(_, _, _, _) ->
    {error, invalid_actor}.

release(Pid, Holder, Token) when is_pid(Pid) ->
    gen_server:call(Pid, {release, Holder, Token});
release(_, _, _) ->
    {error, invalid_actor}.

status(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, status);
status(_) ->
    {error, invalid_actor}.

init({RuntimeEpoch, OwnerEpoch}) ->
    {ok, #{runtime_epoch => RuntimeEpoch,
           owner_epoch => OwnerEpoch,
           sequence => 0,
           holder => undefined,
           expires_at_ms => 0}}.

handle_call({acquire, Holder, LeaseMs}, _From, State0) ->
    case valid_holder(Holder) andalso valid_lease_ms(LeaseMs) of
        false ->
            {reply, {error, invalid_acquire}, State0};
        true ->
            State = expire(State0),
            case maps:get(holder, State) of
                undefined ->
                    Sequence = maps:get(sequence, State) + 1,
                    ExpiresAt = now_ms() + LeaseMs,
                    Next = State#{sequence => Sequence,
                                  holder => Holder,
                                  expires_at_ms => ExpiresAt},
                    {reply, {ok, grant(Next)}, Next};
                Holder ->
                    {reply, {ok, grant(State)}, State};
                _Other ->
                    {reply, {error, {busy, remaining_ms(State)}}, State}
            end
    end;
handle_call({renew, Holder, Token, LeaseMs}, _From, State0) ->
    case valid_holder(Holder) andalso valid_lease_ms(LeaseMs) of
        false ->
            {reply, {error, invalid_renew}, State0};
        true ->
            State = expire(State0),
            case owns(State, Holder, Token) of
                true ->
                    Next = State#{expires_at_ms => now_ms() + LeaseMs},
                    {reply, {ok, grant(Next)}, Next};
                false ->
                    {reply, {error, stale_or_not_owner}, State}
            end
    end;
handle_call({release, Holder, Token}, _From, State0) ->
    State = expire(State0),
    case owns(State, Holder, Token) of
        true ->
            Next = State#{holder => undefined, expires_at_ms => 0},
            {reply, ok, Next};
        false ->
            {reply, {error, stale_or_not_owner}, State}
    end;
handle_call(status, _From, State0) ->
    State = expire(State0),
    {reply, State#{remaining_ms => remaining_ms(State)}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) -> {noreply, State}.
handle_info(_Message, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

grant(State) ->
    #{token => #{runtime_epoch => maps:get(runtime_epoch, State),
                 owner_epoch => maps:get(owner_epoch, State),
                 sequence => maps:get(sequence, State)},
      expires_at_ms => maps:get(expires_at_ms, State)}.

owns(State, Holder, #{runtime_epoch := RuntimeEpoch,
                      owner_epoch := OwnerEpoch,
                      sequence := Sequence}) ->
    maps:get(holder, State) =:= Holder
    andalso maps:get(runtime_epoch, State) =:= RuntimeEpoch
    andalso maps:get(owner_epoch, State) =:= OwnerEpoch
    andalso maps:get(sequence, State) =:= Sequence
    andalso maps:get(expires_at_ms, State) > now_ms();
owns(_, _, _) -> false.

expire(State) ->
    case maps:get(holder, State) of
        undefined -> State;
        _ ->
            case maps:get(expires_at_ms, State) =< now_ms() of
                true -> State#{holder => undefined, expires_at_ms => 0};
                false -> State
            end
    end.

remaining_ms(State) ->
    erlang:max(0, maps:get(expires_at_ms, State) - now_ms()).

valid_holder(Value) when is_binary(Value),
                         byte_size(Value) > 0,
                         byte_size(Value) =< 256 ->
    binary:match(Value, <<0>>) =:= nomatch;
valid_holder(_) -> false.

valid_lease_ms(Value) when is_integer(Value), Value > 0 ->
    Max = application:get_env(bmscl_supervisor, critical_section_max_lease_ms, 300000),
    Value =< Max;
valid_lease_ms(_) -> false.

now_ms() -> erlang:monotonic_time(millisecond).
