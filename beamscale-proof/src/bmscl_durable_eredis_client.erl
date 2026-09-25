-module(bmscl_durable_eredis_client).

-export([start_command/1, q/2]).

start_command(Options) ->
    eredis:start_link(Options).

q(Pid, Command) when is_pid(Pid), is_list(Command) ->
    eredis:q(Pid, Command).
