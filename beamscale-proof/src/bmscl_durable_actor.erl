-module(bmscl_durable_actor).
-behaviour(gen_server).

-export([start/2, admit_turn/2, info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start(Placement, Epoch) when is_map(Placement), is_integer(Epoch), Epoch > 0 ->
    gen_server:start(?MODULE, {Placement, Epoch}, []).

admit_turn(Pid, Placement) when is_pid(Pid), is_map(Placement) ->
    gen_server:call(Pid, {admit_turn, Placement});
admit_turn(_, _) ->
    {error, invalid_turn}.

info(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, info);
info(_) ->
    {error, invalid_actor_pid}.

init({Placement, Epoch}) ->
    ActorKey = maps:get(actor_key, Placement),
    {ok, #{
        actor_key => ActorKey,
        tenant_id => maps:get(tenant_id, Placement),
        application_id => maps:get(application_id, Placement),
        namespace => maps:get(namespace, Placement),
        actor_bucket => maps:get(actor_bucket, Placement),
        deployment_id => maps:get(deployment_id, Placement, undefined),
        epoch => Epoch,
        sequence => 0,
        seen_shards => #{}
    }}.

handle_call({admit_turn, Placement}, _From, State0) ->
    case placement_matches_actor(Placement, State0) of
        false ->
            {reply, {error, tenant_or_actor_mismatch}, State0};
        true ->
            Sequence = maps:get(sequence, State0) + 1,
            VirtualShard = maps:get(virtual_shard, Placement),
            Seen0 = maps:get(seen_shards, State0),
            Seen1 = maps:put(VirtualShard, true, Seen0),
            Token = #{
                epoch => maps:get(epoch, State0),
                sequence => Sequence,
                virtual_shard => VirtualShard,
                actor_bucket => maps:get(actor_bucket, State0),
                object_key => maps:get(object_key, Placement),
                actor_key => maps:get(actor_key, State0)
            },
            {reply, {ok, Token}, State0#{sequence => Sequence, seen_shards => Seen1}}
    end;
handle_call(info, _From, State) ->
    Info = maps:without([seen_shards], State),
    {reply, Info#{shard_count => map_size(maps:get(seen_shards, State))}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_call}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

placement_matches_actor(Placement, State) ->
    maps:get(actor_key, Placement, undefined) =:= maps:get(actor_key, State)
    andalso maps:get(tenant_id, Placement, undefined) =:= maps:get(tenant_id, State).
