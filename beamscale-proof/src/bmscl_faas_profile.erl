-module(bmscl_faas_profile).

-export([normalize/1, execution_class/1, profile/1, ensure_enabled/1]).

-define(DEFAULT_DRAIN_TIMEOUT_MS, 30000).
-define(DEFAULT_VIRTUAL_SHARDS, 4096).
-define(DEFAULT_SHARDS_PER_ACTOR, 64).

-spec normalize(map()) -> {ok, map()} | {error, term()}.
normalize(Target) when is_map(Target) ->
    case {enum(execution_class, value(execution_class, Target, request),
               [request, connection, durable_actor]),
          enum(experimental_profile, value(experimental_profile, Target, undefined),
               [undefined, phoenix_v1, durable_actor_v1]),
          enum(protocol, value(protocol, Target, http), [http, websocket])} of
        {{ok, Class}, {ok, Profile}, {ok, Protocol}} ->
            validate(Profile, Class, Protocol, Target);
        {{error, Reason}, _, _} -> {error, Reason};
        {_, {error, Reason}, _} -> {error, Reason};
        {_, _, {error, Reason}} -> {error, Reason}
    end;
normalize(_) ->
    {error, invalid_route_target}.

execution_class(Target) when is_map(Target) ->
    maps:get(execution_class, Target, request).

profile(Target) when is_map(Target) ->
    maps:get(experimental_profile, Target, undefined).

ensure_enabled(Target) ->
    case profile(Target) of
        undefined -> ok;
        Profile ->
            Enabled = application:get_env(bmscl_supervisor, experimental_faas_profiles, []),
            case profile_enabled(Profile, Enabled) of
                true -> ok;
                false -> {error, {experimental_profile_disabled, Profile}}
            end
    end.

%% Preserve the existing route target shape for ordinary lambdas. The runtime
%% accessors already default missing fields to request/http, so legacy manifests
%% remain byte-for-byte compatible unless an experimental profile is selected.
validate(undefined, request, http, _Target) ->
    {ok, #{}};
validate(undefined, Class, _Protocol, _Target) ->
    {error, {experimental_profile_required, Class}};
validate(phoenix_v1, request, http, _Target) ->
    {ok, #{execution_class => request,
           experimental_profile => phoenix_v1,
           protocol => http}};
validate(phoenix_v1, connection, websocket, Target) ->
    case positive_int(value(drain_timeout_ms, Target, ?DEFAULT_DRAIN_TIMEOUT_MS),
                      1000, 300000) of
        {ok, DrainTimeoutMs} ->
            {ok, #{execution_class => connection,
                   experimental_profile => phoenix_v1,
                   protocol => websocket,
                   drain_timeout_ms => DrainTimeoutMs}};
        error ->
            {error, invalid_drain_timeout_ms}
    end;
validate(phoenix_v1, connection, Protocol, _Target) ->
    {error, {phoenix_connection_requires_websocket, Protocol}};
validate(phoenix_v1, Class, _Protocol, _Target) ->
    {error, {unsupported_phoenix_execution_class, Class}};
validate(durable_actor_v1, durable_actor, http, Target) ->
    Namespace0 = value(namespace, Target, undefined),
    case {nonempty_binary(Namespace0, 256),
          positive_int(value(virtual_shards, Target, ?DEFAULT_VIRTUAL_SHARDS), 64, 65536),
          positive_int(value(shards_per_actor, Target, ?DEFAULT_SHARDS_PER_ACTOR), 1, 4096)} of
        {{ok, Namespace}, {ok, VirtualShards}, {ok, ShardsPerActor}}
          when ShardsPerActor =< VirtualShards,
               VirtualShards rem ShardsPerActor =:= 0 ->
            {ok, #{execution_class => durable_actor,
                   experimental_profile => durable_actor_v1,
                   protocol => http,
                   namespace => Namespace,
                   virtual_shards => VirtualShards,
                   shards_per_actor => ShardsPerActor}};
        {error, _, _} -> {error, invalid_durable_namespace};
        {_, error, _} -> {error, invalid_virtual_shards};
        {_, _, error} -> {error, invalid_shards_per_actor};
        _ -> {error, invalid_durable_shard_layout}
    end;
validate(durable_actor_v1, durable_actor, Protocol, _Target) ->
    {error, {durable_actor_requires_http, Protocol}};
validate(durable_actor_v1, Class, _Protocol, _Target) ->
    {error, {unsupported_durable_execution_class, Class}}.

enum(Key, Value, Allowed) ->
    case enum_atom(Value) of
        {ok, Atom} ->
            case lists:member(Atom, Allowed) of
                true -> {ok, Atom};
                false -> {error, {invalid_faas_profile_value, Key, Value}}
            end;
        error ->
            {error, {invalid_faas_profile_value, Key, Value}}
    end.

enum_atom(undefined) -> {ok, undefined};
enum_atom(Value) when is_atom(Value) -> {ok, Value};
enum_atom(Value) when is_list(Value) -> enum_atom(unicode:characters_to_binary(Value));
enum_atom(<<"request">>) -> {ok, request};
enum_atom(<<"connection">>) -> {ok, connection};
enum_atom(<<"durable_actor">>) -> {ok, durable_actor};
enum_atom(<<"phoenix_v1">>) -> {ok, phoenix_v1};
enum_atom(<<"durable_actor_v1">>) -> {ok, durable_actor_v1};
enum_atom(<<"http">>) -> {ok, http};
enum_atom(<<"websocket">>) -> {ok, websocket};
enum_atom(_) -> error.

profile_enabled(_Profile, all) -> true;
profile_enabled(Profile, Enabled) when is_list(Enabled) ->
    lists:any(fun(Item) -> profile_item(Item) =:= Profile end, Enabled);
profile_enabled(_Profile, _) -> false.

profile_item(Item) when is_atom(Item) -> Item;
profile_item(Item) when is_list(Item) -> profile_item(unicode:characters_to_binary(Item));
profile_item(<<"phoenix_v1">>) -> phoenix_v1;
profile_item(<<"durable_actor_v1">>) -> durable_actor_v1;
profile_item(_) -> invalid.

positive_int(Value, Min, Max)
  when is_integer(Value), Value >= Min, Value =< Max -> {ok, Value};
positive_int(_, _, _) -> error.

nonempty_binary(Value, Max) when is_binary(Value),
                                 byte_size(Value) > 0,
                                 byte_size(Value) =< Max ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, Value};
        _ -> error
    end;
nonempty_binary(Value, Max) when is_list(Value) ->
    nonempty_binary(unicode:characters_to_binary(Value), Max);
nonempty_binary(_, _) -> error.

value(Key, Map, Default) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error -> maps:get(atom_to_binary(Key, utf8), Map, Default)
    end.
