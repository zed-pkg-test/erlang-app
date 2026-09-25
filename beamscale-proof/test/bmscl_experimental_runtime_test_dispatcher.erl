-module(bmscl_experimental_runtime_test_dispatcher).

-export([invoke_async/3, register_connection/3, locate_durable_actor/4]).

invoke_async(Target, Request, Context) ->
    {ok, {external_invoke, Target, Request, Context}}.

register_connection(Target, TransportPid, Context) ->
    {ok, {external_connection, Target, TransportPid, Context}}.

locate_durable_actor(Target, TenantId, ApplicationId, ObjectKey) ->
    {ok, {external_durable, Target, TenantId, ApplicationId, ObjectKey}}.
