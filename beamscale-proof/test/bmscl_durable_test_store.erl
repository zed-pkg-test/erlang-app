-module(bmscl_durable_test_store).
-behaviour(bmscl_durable_store).

-export([reset/0, load/2, claim_owner/1, commit/5]).

-define(TABLE, bmscl_durable_test_store_table).

reset() ->
    case ets:whereis(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE), ok
    end.

load(Identity, _OwnerScope) ->
    Tab = ensure_table(),
    case ets:lookup(Tab, {object, Identity}) of
        [] -> {ok, not_found};
        [{{object, Identity}, Version, State}] ->
            {ok, #{version => Version, state => State}}
    end.

claim_owner(OwnerScope) ->
    Tab = ensure_table(),
    Epoch = ets:update_counter(
              Tab,
              {owner, OwnerScope},
              {2, 1},
              {{owner, OwnerScope}, 0}),
    {ok, Epoch}.

commit(Identity, ExpectedVersion, OwnerScope, OwnerEpoch, Payload)
  when is_integer(ExpectedVersion), ExpectedVersion >= 0,
       is_integer(OwnerEpoch), OwnerEpoch > 0,
       is_binary(Payload) ->
    Tab = ensure_table(),
    case ets:lookup(Tab, {owner, OwnerScope}) of
        [] ->
            {error, owner_missing};
        [{{owner, OwnerScope}, CurrentOwner}] when CurrentOwner =/= OwnerEpoch ->
            {error, {stale_owner_epoch, CurrentOwner}};
        [{{owner, OwnerScope}, OwnerEpoch}] ->
            CurrentVersion = case ets:lookup(Tab, {object, Identity}) of
                [] -> 0;
                [{{object, Identity}, Version, _}] -> Version
            end,
            case CurrentVersion =:= ExpectedVersion of
                false -> {error, {stale_version, CurrentVersion}};
                true ->
                    Next = CurrentVersion + 1,
                    true = ets:insert(Tab, {{object, Identity}, Next, Payload}),
                    {ok, Next}
            end
    end;
commit(_, _, _, _, _) ->
    {error, invalid_durable_commit}.

ensure_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            try ets:new(
                  ?TABLE,
                  [named_table, public, set,
                   {read_concurrency, true}, {write_concurrency, true}]) of
                Tab -> Tab
            catch
                error:badarg -> ?TABLE
            end;
        Tab -> Tab
    end.
