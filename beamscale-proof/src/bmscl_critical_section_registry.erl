-module(bmscl_critical_section_registry).
-behaviour(gen_server).

-export([start_link/0, acquire/6, renew/7, release/6, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {tenant_id = undefined, actors = #{}, monitors = #{}}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

acquire(TenantId, Namespace, ObjectKey, RuntimeEpoch, Holder, LeaseMs) ->
    gen_server:call(?MODULE,
                    {acquire, TenantId, Namespace, ObjectKey,
                     RuntimeEpoch, Holder, LeaseMs}, infinity).

renew(TenantId, Namespace, ObjectKey, RuntimeEpoch, Holder, Token, LeaseMs) ->
    gen_server:call(?MODULE,
                    {renew, TenantId, Namespace, ObjectKey,
                     RuntimeEpoch, Holder, Token, LeaseMs}, infinity).

release(TenantId, Namespace, ObjectKey, RuntimeEpoch, Holder, Token) ->
    gen_server:call(?MODULE,
                    {release, TenantId, Namespace, ObjectKey,
                     RuntimeEpoch, Holder, Token}, infinity).

status() -> gen_server:call(?MODULE, status).

init([]) -> {ok, #state{}}.

handle_call({acquire, T, N, K, Epoch, Holder, LeaseMs}, _From, State0) ->
    with_actor(T, N, K, Epoch, State0,
      fun(Pid, State1) ->
          {reply, bmscl_critical_section_actor:acquire(Pid, Holder, LeaseMs), State1}
      end);
handle_call({renew, T, N, K, Epoch, Holder, Token, LeaseMs}, _From, State0) ->
    with_actor(T, N, K, Epoch, State0,
      fun(Pid, State1) ->
          {reply, bmscl_critical_section_actor:renew(Pid, Holder, Token, LeaseMs), State1}
      end);
handle_call({release, T, N, K, Epoch, Holder, Token}, _From, State0) ->
    with_actor(T, N, K, Epoch, State0,
      fun(Pid, State1) ->
          {reply, bmscl_critical_section_actor:release(Pid, Holder, Token), State1}
      end);
handle_call(status, _From, State) ->
    Actors = maps:map(fun(_Key, Actor) -> maps:without([monitor], Actor) end,
                      State#state.actors),
    {reply, #{tenant_id => State#state.tenant_id,
              actor_count => map_size(Actors),
              actors => Actors}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info({'DOWN', Mon, process, _Pid, _Reason}, State0) ->
    case maps:take(Mon, State0#state.monitors) of
        error -> {noreply, State0};
        {Key, Monitors1} ->
            {noreply, State0#state{
                monitors = Monitors1,
                actors = maps:remove(Key, State0#state.actors)
            }}
    end;
handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(fun(_Key, Actor) ->
                     _ = catch gen_server:stop(maps:get(pid, Actor), normal, 1000)
                 end, State#state.actors),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

with_actor(T0, N0, K0, Epoch, State0, Fun)
  when is_integer(Epoch), Epoch > 0, is_function(Fun, 2) ->
    case {text(T0, 1024), namespace(N0), text(K0, 4096)} of
        {{ok, T}, {ok, N}, {ok, K}} ->
            %% This registry lives inside a tenant-dedicated BEAM VM. Bind the
            %% process to the first admitted tenant and fail closed if any
            %% cross-tenant call reaches it.
            case bind_tenant(T, State0) of
                {ok, BoundState} ->
                    Key = {T, N, K},
                    case ensure_actor(Key, Epoch, BoundState) of
                        {ok, Pid, State1} -> Fun(Pid, State1);
                        {error, Reason, State1} -> {reply, {error, Reason}, State1}
                    end;
                {error, Reason, State1} ->
                    {reply, {error, Reason}, State1}
            end;
        _ -> {reply, {error, invalid_critical_section_identity}, State0}
    end;
with_actor(_, _, _, _, State, _Fun) ->
    {reply, {error, invalid_runtime_epoch}, State}.

bind_tenant(Tenant, State = #state{tenant_id = undefined}) ->
    {ok, State#state{tenant_id = Tenant}};
bind_tenant(Tenant, State = #state{tenant_id = Tenant}) ->
    {ok, State};
bind_tenant(_Tenant, State = #state{tenant_id = Existing}) ->
    {error, {tenant_vm_mismatch, Existing}, State}.

ensure_actor(Key, Epoch, State0) ->
    case maps:find(Key, State0#state.actors) of
        error -> start_actor(Key, Epoch, State0);
        {ok, Actor} ->
            Pid = maps:get(pid, Actor),
            ExistingEpoch = maps:get(runtime_epoch, Actor),
            case {is_process_alive(Pid), Epoch - ExistingEpoch} of
                {false, _} ->
                    start_actor(Key, Epoch, remove_actor(Key, Actor, State0));
                {true, 0} ->
                    {ok, Pid, State0};
                {true, Delta} when Delta > 0 ->
                    State1 = remove_actor(Key, Actor, State0),
                    _ = catch gen_server:stop(Pid, normal, 1000),
                    start_actor(Key, Epoch, State1);
                {true, _Negative} ->
                    {error, {stale_runtime_epoch, ExistingEpoch}, State0}
            end
    end.

start_actor(Key, RuntimeEpoch, State0) ->
    case claim_owner_epoch(Key) of
        {error, Reason} ->
            {error, {critical_section_owner_claim_failed, Reason}, State0};
        {ok, OwnerEpoch} ->
            case bmscl_critical_section_actor:start(RuntimeEpoch, OwnerEpoch) of
                {ok, Pid} ->
                    Mon = erlang:monitor(process, Pid),
                    Actor = #{pid => Pid,
                              monitor => Mon,
                              runtime_epoch => RuntimeEpoch,
                              owner_epoch => OwnerEpoch},
                    {ok, Pid, State0#state{
                        actors = maps:put(Key, Actor, State0#state.actors),
                        monitors = maps:put(Mon, Key, State0#state.monitors)
                    }};
                {error, Reason} ->
                    {error, {critical_section_actor_start_failed, Reason}, State0}
            end
    end.

claim_owner_epoch({Tenant, Namespace, ObjectKey}) ->
    Store = application:get_env(
              bmscl_supervisor, durable_store_module, bmscl_durable_store_redis),
    Scope = critical_section_owner_scope(Tenant, Namespace, ObjectKey),
    try Store:claim_owner(Scope) of
        {ok, Epoch} when is_integer(Epoch), Epoch > 0 -> {ok, Epoch};
        {error, Reason} -> {error, Reason};
        Other -> {error, {invalid_owner_claim_result, Other}}
    catch
        Class:Reason -> {error, {owner_claim_exception, Class, Reason}}
    end.

critical_section_owner_scope(Tenant, Namespace, ObjectKey) ->
    Hash = crypto:hash(
             sha256,
             term_to_binary(
               {<<"bmscl-critical-section-v1">>, Tenant, Namespace, ObjectKey},
               [deterministic])),
    #{
        tenant_id => Tenant,
        application_id => <<"critical-sections">>,
        namespace => Namespace,
        %% A critical-section key is itself the independently movable/fenced
        %% authority. The full SHA-256 integer avoids multiplexing unrelated
        %% lock keys under one owner epoch.
        virtual_shard => binary:decode_unsigned(Hash)
    }.

remove_actor(Key, Actor, State0) ->
    Mon = maps:get(monitor, Actor),
    erlang:demonitor(Mon, [flush]),
    State0#state{
        actors = maps:remove(Key, State0#state.actors),
        monitors = maps:remove(Mon, State0#state.monitors)
    }.

text(Value, Max) when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< Max ->
    case binary:match(Value, <<0>>) of nomatch -> {ok, Value}; _ -> {error, invalid} end;
text(Value, Max) when is_list(Value) -> text(unicode:characters_to_binary(Value), Max);
text(_, _) -> {error, invalid}.

namespace(Value) ->
    case text(Value, 128) of
        {ok, Bin} ->
            case re:run(Bin, <<"^[A-Za-z0-9._-]+$">>, [{capture, none}]) of
                match -> {ok, Bin};
                nomatch -> {error, invalid}
            end;
        Error -> Error
    end.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

tenant_vm_binding_test() ->
    S0 = #state{},
    {ok, S1} = bind_tenant(<<"tenant-a">>, S0),
    ?assertEqual(<<"tenant-a">>, S1#state.tenant_id),
    {ok, S2} = bind_tenant(<<"tenant-a">>, S1),
    ?assertEqual(<<"tenant-a">>, S2#state.tenant_id),
    ?assertMatch({error, {tenant_vm_mismatch, <<"tenant-a">>}, _},
                 bind_tenant(<<"tenant-b">>, S2)).

-endif.
