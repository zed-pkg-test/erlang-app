-module(bmscl_runtime_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) -> {error, {already_started, Pid}};
        undefined ->
            Deadline = erlang:monotonic_time(millisecond) + 10000,
            case await_previous_services(service_names(), Deadline) of
                ok -> supervisor:start_link({local, ?MODULE}, ?MODULE, []);
                Error -> Error
            end
    end.

service_names() ->
    Base0 = [bmscl_invocation_sup, bmscl_guest_control, bmscl_route_refresh,
             bmscl_route_redis_source, bmscl_route_table, bmscl_phoenix_connections,
             bmscl_durable_store_redis, bmscl_durable_registry, bmscl_critical_section_registry, bmscl_env_cache, bmscl_middleware_chain,
             bmscl_budget_manager, bmscl_authority_broker, bmscl_deployment_manager],
    Base = case bmscl_provider_runtime:mode() of
        native -> Base0;
        _ -> [bmscl_provider_runtime | Base0]
    end,
    case application:get_env(bmscl_supervisor, http_provider_module, undefined) of
        bmscl_httpc_provider -> [bmscl_http_request_manager | Base];
        _ -> Base
    end.

await_previous_services([], _Deadline) -> ok;
await_previous_services([Name | Rest], Deadline) ->
    case whereis(Name) of
        undefined -> await_previous_services(Rest, Deadline);
        Pid ->
            Mon = erlang:monitor(process, Pid),
            Remaining = erlang:max(0, Deadline - erlang:monotonic_time(millisecond)),
            receive
                {'DOWN', Mon, process, Pid, _} ->
                    await_previous_services(Rest, Deadline)
            after Remaining ->
                erlang:demonitor(Mon, [flush]),
                {error, {previous_runtime_still_stopping, Name}}
            end
    end.

init([]) ->
    Prefix = [
        #{id => bmscl_deployment_manager,
          start => {bmscl_deployment_manager, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_deployment_manager]},
        #{id => bmscl_env_cache,
          start => {bmscl_env_cache, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_env_cache]},
        #{id => bmscl_authority_broker,
          start => {bmscl_authority_broker, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_authority_broker]},
        #{id => bmscl_budget_manager,
          start => {bmscl_budget_manager, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_budget_manager]},
        #{id => bmscl_route_table,
          start => {bmscl_route_table, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_route_table]},
        #{id => bmscl_middleware_chain,
          start => {bmscl_middleware_chain, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_middleware_chain]},
        #{id => bmscl_phoenix_connections,
          start => {bmscl_phoenix_connections, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_phoenix_connections]},
        #{id => bmscl_durable_store_redis,
          start => {bmscl_durable_store_redis, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_durable_store_redis]},
        #{id => bmscl_durable_registry,
          start => {bmscl_durable_registry, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_durable_registry]},
        #{id => bmscl_critical_section_registry,
          start => {bmscl_critical_section_registry, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_critical_section_registry]}
    ],
    Suffix = [
        #{id => bmscl_route_refresh,
          start => {bmscl_route_refresh, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_route_refresh]},
        #{id => bmscl_invocation_sup,
          start => {bmscl_invocation_sup, start_link, []},
          restart => permanent,
          shutdown => infinity,
          type => supervisor,
          modules => [bmscl_invocation_sup]},
        #{id => bmscl_guest_control,
          start => {bmscl_guest_control, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [bmscl_guest_control]}
    ],
    Children = Prefix ++ http_request_children() ++ route_source_children() ++
               Suffix ++ provider_children(),
    {ok, {{one_for_all, 5, 10}, Children}}.

http_request_children() ->
    case application:get_env(bmscl_supervisor, http_provider_module, undefined) of
        bmscl_httpc_provider ->
            [#{id => bmscl_http_request_manager,
               start => {bmscl_http_request_manager, start_link, []},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [bmscl_http_request_manager]}];
        _ ->
            []
    end.

route_source_children() ->
    case application:get_env(bmscl_supervisor, route_source_module, undefined) of
        bmscl_route_redis_source ->
            [#{id => bmscl_route_redis_source,
               start => {bmscl_route_redis_source, start_link, []},
               restart => permanent,
               shutdown => 5000,
               type => worker,
               modules => [bmscl_route_redis_source]}];
        _ ->
            []
    end.


provider_children() ->
    case bmscl_provider_runtime:mode() of
        native -> [];
        _ ->
            [#{id => bmscl_provider_runtime,
               start => {bmscl_provider_runtime, start_link, []},
               restart => permanent,
               shutdown => 10000,
               type => worker,
               modules => [bmscl_provider_runtime]}]
    end.
