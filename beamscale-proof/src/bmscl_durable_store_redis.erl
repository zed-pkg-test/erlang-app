-module(bmscl_durable_store_redis).
-behaviour(gen_server).
-behaviour(bmscl_durable_store).

-export([start_link/0, load/2, claim_owner/1, commit/5, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
    client_module = bmscl_durable_eredis_client,
    command = undefined,
    redis_options = [],
    prefix = <<"bmscl:durable">>,
    config_error = undefined,
    retry_ms = 500,
    retry_max_ms = 30000,
    base_retry_ms = 500,
    last_error = undefined
}).

-define(COMMIT_LUA, <<
"local owner=redis.call('GET',KEYS[1]);",
"if not owner then return {0,'owner_missing'} end;",
"if owner~=ARGV[1] then return {2,owner} end;",
"local current=redis.call('HGET',KEYS[2],'version');",
"if not current then current='0' end;",
"if current~=ARGV[2] then return {3,current} end;",
"local nextv=redis.call('HINCRBY',KEYS[2],'version',1);",
"redis.call('HSET',KEYS[2],'state',ARGV[3]);",
"return {1,tostring(nextv)}"
>>).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

load(Identity, OwnerScope) ->
    gen_server:call(?MODULE, {load, Identity, OwnerScope}, infinity).

claim_owner(OwnerScope) ->
    gen_server:call(?MODULE, {claim_owner, OwnerScope}, infinity).

commit(Identity, ExpectedVersion, OwnerScope, OwnerEpoch, Payload) ->
    gen_server:call(
      ?MODULE,
      {commit, Identity, ExpectedVersion, OwnerScope, OwnerEpoch, Payload},
      infinity).

status() ->
    gen_server:call(?MODULE, status).

init([]) ->
    process_flag(trap_exit, true),
    State0 = load_config(),
    self() ! connect,
    {ok, State0}.

handle_call(status, _From, State) ->
    {reply, #{
        connected => is_live_pid(State#state.command),
        prefix => State#state.prefix,
        last_error => State#state.last_error,
        config_error => State#state.config_error
    }, State};
handle_call(_Request, _From, State = #state{config_error = Reason})
  when Reason =/= undefined ->
    {reply, {error, {invalid_durable_redis_config, Reason}}, State};
handle_call(_Request, _From, State = #state{command = Command})
  when not is_pid(Command) ->
    {reply, {error, durable_store_unavailable}, State};
handle_call({claim_owner, OwnerScope}, _From, State) ->
    Reply = with_scope_key(OwnerScope, State,
      fun(OwnerKey, _Tag) ->
          query(State, [<<"INCR">>, OwnerKey], fun decode_positive_integer/1)
      end),
    {reply, Reply, remember_error(Reply, State)};
handle_call({load, Identity, OwnerScope}, _From, State) ->
    Reply = with_object_keys(Identity, OwnerScope, State,
      fun(_OwnerKey, ObjectKey) ->
          query(
            State,
            [<<"HMGET">>, ObjectKey, <<"version">>, <<"state">>],
            fun decode_loaded/1)
      end),
    {reply, Reply, remember_error(Reply, State)};
handle_call({commit, Identity, ExpectedVersion, OwnerScope, OwnerEpoch, Payload},
            _From, State)
  when is_integer(ExpectedVersion), ExpectedVersion >= 0,
       is_integer(OwnerEpoch), OwnerEpoch > 0,
       is_binary(Payload) ->
    Reply = with_object_keys(Identity, OwnerScope, State,
      fun(OwnerKey, ObjectKey) ->
          Args = [
              <<"EVAL">>, ?COMMIT_LUA, <<"2">>, OwnerKey, ObjectKey,
              integer_to_binary(OwnerEpoch),
              integer_to_binary(ExpectedVersion),
              Payload
          ],
          query(State, Args, fun decode_commit/1)
      end),
    {reply, Reply, remember_error(Reply, State)};
handle_call({commit, _, _, _, _, _}, _From, State) ->
    {reply, {error, invalid_durable_commit}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(connect, State = #state{config_error = Reason}) when Reason =/= undefined ->
    {noreply, State};
handle_info(connect, State0) ->
    {noreply, connect(State0)};
handle_info({'EXIT', Pid, Reason}, State = #state{command = Pid}) ->
    State1 = State#state{command = undefined, last_error = {redis_client_exit, Reason}},
    {noreply, schedule_reconnect(State1)};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    stop_pid(State#state.command),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

load_config() ->
    Config0 = application:get_env(bmscl_supervisor, durable_redis, #{}),
    Config = case is_map(Config0) of true -> Config0; false -> #{} end,
    Client = application:get_env(
               bmscl_supervisor,
               durable_redis_client_module,
               bmscl_durable_eredis_client),
    BaseRetry = positive_integer(maps:get(retry_ms, Config, 500), 500),
    RetryMax = erlang:max(
                 BaseRetry,
                 positive_integer(maps:get(retry_max_ms, Config, 30000), 30000)),
    Prefix = as_binary(maps:get(prefix, Config, <<"bmscl:durable">>)),
    case {valid_prefix(Prefix), redis_options(Config)} of
        {true, {ok, Options}} ->
            #state{
                client_module = Client,
                redis_options = Options,
                prefix = Prefix,
                base_retry_ms = BaseRetry,
                retry_ms = BaseRetry,
                retry_max_ms = RetryMax
            };
        {false, _} ->
            #state{client_module = Client, prefix = Prefix, config_error = invalid_prefix};
        {_, {error, Reason}} ->
            #state{client_module = Client, prefix = Prefix, config_error = Reason}
    end.

connect(State = #state{command = Command}) when is_pid(Command) ->
    State;
connect(State0) ->
    Client = State0#state.client_module,
    try Client:start_command(State0#state.redis_options) of
        {ok, Pid} when is_pid(Pid) ->
            State0#state{
                command = Pid,
                retry_ms = State0#state.base_retry_ms,
                last_error = undefined
            };
        {error, Reason} ->
            schedule_reconnect(State0#state{last_error = {connect, Reason}});
        Other ->
            schedule_reconnect(State0#state{last_error = {connect, Other}})
    catch
        Class:Reason ->
            schedule_reconnect(State0#state{last_error = {connect, Class, Reason}})
    end.

query(State, Args, Decoder) ->
    Client = State#state.client_module,
    Command = State#state.command,
    try Client:q(Command, Args) of
        {ok, Value} -> Decoder(Value);
        {error, Reason} -> {error, {redis, Reason}};
        Other -> {error, {unexpected_redis_reply, Other}}
    catch
        Class:Reason -> {error, {redis_query, Class, Reason}}
    end.

with_scope_key(OwnerScope, State, Fun) ->
    case validate_owner_scope(OwnerScope) of
        {ok, Scope} ->
            Tag = digest_term({<<"owner-scope-v1">>, Scope}),
            OwnerKey = <<(State#state.prefix)/binary, ":{", Tag/binary, "}:owner">>,
            Fun(OwnerKey, Tag);
        Error -> Error
    end.

with_object_keys(Identity, OwnerScope, State, Fun) ->
    with_scope_key(OwnerScope, State,
      fun(OwnerKey, Tag) ->
          case validate_identity(Identity, OwnerScope) of
              {ok, CanonicalIdentity} ->
                  ObjectDigest = digest_term({<<"object-v1">>, CanonicalIdentity}),
                  ObjectKey = <<(State#state.prefix)/binary, ":{", Tag/binary,
                                "}:object:", ObjectDigest/binary>>,
                  Fun(OwnerKey, ObjectKey);
              Error -> Error
          end
      end).

validate_owner_scope(#{
    tenant_id := Tenant,
    application_id := Application,
    namespace := Namespace,
    virtual_shard := VirtualShard
}) when is_integer(VirtualShard), VirtualShard >= 0 ->
    case {safe_binary(Tenant, 1024), safe_binary(Application, 1024),
          safe_binary(Namespace, 128)} of
        {{ok, T}, {ok, A}, {ok, N}} ->
            {ok, {T, A, N, VirtualShard}};
        _ -> {error, invalid_owner_scope}
    end;
validate_owner_scope(_) ->
    {error, invalid_owner_scope}.

validate_identity(#{
    tenant_id := Tenant,
    application_id := Application,
    namespace := Namespace,
    object_key := ObjectKey
}, OwnerScope) ->
    case {safe_binary(Tenant, 1024), safe_binary(Application, 1024),
          safe_binary(Namespace, 128), safe_binary(ObjectKey, 4096),
          validate_owner_scope(OwnerScope)} of
        {{ok, T}, {ok, A}, {ok, N}, {ok, K}, {ok, {T, A, N, _}}} ->
            {ok, {T, A, N, K}};
        _ -> {error, invalid_durable_identity}
    end;
validate_identity(_, _) ->
    {error, invalid_durable_identity}.

decode_positive_integer(Value) ->
    case parse_non_negative_integer(Value) of
        {ok, N} when N > 0 -> {ok, N};
        _ -> {error, invalid_owner_epoch}
    end.

decode_loaded([undefined, undefined]) ->
    {ok, not_found};
decode_loaded([Version0, State]) when is_binary(State) ->
    case parse_non_negative_integer(Version0) of
        {ok, Version} -> {ok, #{version => Version, state => State}};
        error -> {error, invalid_durable_version}
    end;
decode_loaded(Other) ->
    {error, {invalid_durable_load_reply, Other}}.

decode_commit([Code0, Value]) ->
    case parse_non_negative_integer(Code0) of
        {ok, 1} ->
            case parse_non_negative_integer(Value) of
                {ok, Version} -> {ok, Version};
                error -> {error, invalid_durable_version}
            end;
        {ok, 2} ->
            case parse_non_negative_integer(Value) of
                {ok, Epoch} -> {error, {stale_owner_epoch, Epoch}};
                error -> {error, stale_owner_epoch}
            end;
        {ok, 3} ->
            case parse_non_negative_integer(Value) of
                {ok, Version} -> {error, {stale_version, Version}};
                error -> {error, stale_version}
            end;
        {ok, 0} -> {error, owner_missing};
        _ -> {error, {invalid_durable_commit_reply, [Code0, Value]}}
    end;
decode_commit(Other) ->
    {error, {invalid_durable_commit_reply, Other}}.

parse_non_negative_integer(Value) when is_integer(Value), Value >= 0 ->
    {ok, Value};
parse_non_negative_integer(Value) when is_binary(Value) ->
    try binary_to_integer(Value) of
        N when N >= 0 -> {ok, N};
        _ -> error
    catch _:_ -> error end;
parse_non_negative_integer(_) ->
    error.

remember_error({ok, _}, State) -> State#state{last_error = undefined};
remember_error(ok, State) -> State#state{last_error = undefined};
remember_error({error, Reason}, State) -> State#state{last_error = Reason};
remember_error(_, State) -> State.

schedule_reconnect(State = #state{retry_ms = Retry, retry_max_ms = Max}) ->
    erlang:send_after(Retry, self(), connect),
    State#state{retry_ms = erlang:min(Max, Retry * 2)}.

redis_options(Config) ->
    Host0 = maps:get(host, Config, "127.0.0.1"),
    Host = case Host0 of Bin when is_binary(Bin) -> binary_to_list(Bin); V -> V end,
    Port = maps:get(port, Config, 6379),
    Database = maps:get(database, Config, 0),
    ConnectTimeout = positive_integer(maps:get(connect_timeout, Config, 5000), 5000),
    ReconnectSleep = positive_integer(maps:get(reconnect_sleep, Config, 100), 100),
    Base = [
        {host, Host},
        {port, Port},
        {database, Database},
        {connect_timeout, ConnectTimeout},
        {reconnect_sleep, ReconnectSleep}
    ],
    WithUser = add_secret_option(username, Config, Base),
    WithPassword = add_secret_option(password, Config, WithUser),
    case maps:get(tls, Config, false) of
        false -> {ok, WithPassword};
        Options when is_list(Options) -> {ok, [{tls, Options} | WithPassword]};
        true -> {error, tls_requires_explicit_options};
        _ -> {error, invalid_tls_configuration}
    end.

add_secret_option(Key, Config, Options) ->
    case maps:find(Key, Config) of
        error -> Options;
        {ok, undefined} -> Options;
        {ok, Value} -> [{Key, fun() -> Value end} | Options]
    end.

safe_binary(Value, Max) when is_binary(Value),
                             byte_size(Value) > 0,
                             byte_size(Value) =< Max ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, Value};
        _ -> error
    end;
safe_binary(_, _) -> error.

digest_term(Term) ->
    Hash = crypto:hash(sha256, term_to_binary(Term, [deterministic])),
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Hash]).

valid_prefix(Prefix) when is_binary(Prefix),
                          byte_size(Prefix) > 0,
                          byte_size(Prefix) =< 128 ->
    binary:match(Prefix, <<0>>) =:= nomatch
    andalso binary:match(Prefix, <<"{">>) =:= nomatch
    andalso binary:match(Prefix, <<"}">>) =:= nomatch;
valid_prefix(_) -> false.

positive_integer(Value, _Default) when is_integer(Value), Value > 0 -> Value;
positive_integer(_, Default) -> Default.

as_binary(Value) when is_binary(Value) -> Value;
as_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
as_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
as_binary(Value) -> unicode:characters_to_binary(io_lib:format("~p", [Value])).

is_live_pid(Pid) when is_pid(Pid) -> is_process_alive(Pid);
is_live_pid(_) -> false.

stop_pid(Pid) when is_pid(Pid) ->
    catch unlink(Pid),
    catch exit(Pid, shutdown),
    ok;
stop_pid(_) -> ok.
