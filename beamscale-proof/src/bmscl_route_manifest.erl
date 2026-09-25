-module(bmscl_route_manifest).

-export([from_map/1, activate/1]).

-define(SCHEMA, <<"ores.routes.v1">>).

-spec activate(map()) -> {ok, updated | unchanged} | {error, term()}.
activate(Manifest) ->
    case from_map(Manifest) of
        {ok, Version, Routes} -> bmscl_route_table:replace_snapshot(Version, Routes);
        Error -> Error
    end.

-spec from_map(map()) -> {ok, non_neg_integer(), map()} | {error, term()}.
from_map(Manifest) when is_map(Manifest) ->
    case {value(schema_version, Manifest), value(routing_version, Manifest), value(routes, Manifest)} of
        {?SCHEMA, Version, Routes0}
          when is_integer(Version), Version >= 1, is_list(Routes0) ->
            compile_routes(Routes0, Version);
        {Schema, _, _} when Schema =/= ?SCHEMA ->
            {error, {unsupported_route_schema, Schema}};
        {_, Version, _} when not is_integer(Version); Version < 1 ->
            {error, invalid_routing_version};
        _ ->
            {error, invalid_route_manifest}
    end;
from_map(_) ->
    {error, invalid_route_manifest}.

compile_routes(Routes0, Version) ->
    case lists:foldl(fun compile_route/2, {ok, #{}, #{}}, Routes0) of
        {ok, Routes, _Shapes} -> {ok, Version, Routes};
        Error -> Error
    end.

compile_route(Route0, {ok, Routes, Shapes}) when is_map(Route0) ->
    Method0 = value(method, Route0),
    Path0 = value(path, Route0),
    RouteId = value(route_id, Route0),
    SourcePath = value(source_path, Route0),
    Target0 = value(target, Route0),
    case {normalize_method(Method0), normalize_path(Path0), compile_target(Target0)} of
        {{ok, Method}, {ok, Path}, {ok, Target0a}} ->
            case validate_route_pattern(Path) of
                ok ->
                    Shape = canonical_shape(Path),
                    ShapeKey = {Method, Shape},
                    Key = {Method, Path},
                    case {maps:is_key(Key, Routes), maps:find(ShapeKey, Shapes)} of
                        {true, _} -> {error, {duplicate_route, Key}};
                        {false, {ok, OtherPath}} when OtherPath =/= Path ->
                            {error, {ambiguous_route_pattern, Method, OtherPath, Path}};
                        {false, _} ->
                            Target = maybe_put(source_path, SourcePath,
                                      maybe_put(route_id, RouteId, Target0a)),
                            {ok, maps:put(Key, Target, Routes), maps:put(ShapeKey, Path, Shapes)}
                    end;
                {error, Reason} -> {error, Reason}
            end;
        {{error, Reason}, _, _} -> {error, Reason};
        {_, {error, Reason}, _} -> {error, Reason};
        {_, _, {error, Reason}} -> {error, Reason}
    end;
compile_route(_, {ok, _, _}) ->
    {error, invalid_route};
compile_route(_, Error) ->
    Error.

compile_target(Target0) when is_map(Target0) ->
    FunctionId = value(function_id, Target0),
    DeploymentId = value(deployment_id, Target0),
    Digest = value(artifact_digest, Target0),
    Runtime = value(runtime, Target0),
    case {valid_nonempty_text(FunctionId), valid_nonempty_text(DeploymentId),
          valid_digest(Digest), beam_entrypoint(Runtime)} of
        {true, true, true, {ok, Entrypoint}} ->
            case bmscl_faas_profile:normalize(Target0) of
                {ok, ProfileFields} ->
                    Base = #{
                        function_id => to_binary(FunctionId),
                        deployment_id => to_binary(DeploymentId),
                        artifact_digest => to_binary(Digest),
                        entrypoint => Entrypoint
                    },
                    {ok, maps:merge(Base, ProfileFields)};
                {error, Reason} ->
                    {error, Reason}
            end;
        {false, _, _, _} -> {error, invalid_function_id};
        {_, false, _, _} -> {error, invalid_deployment_id};
        {_, _, false, _} -> {error, invalid_artifact_digest};
        {_, _, _, {error, Reason}} -> {error, Reason}
    end;
compile_target(_) ->
    {error, invalid_route_target}.

beam_entrypoint(Runtime) when is_map(Runtime) ->
    case {value(kind, Runtime), value(entrypoint, Runtime)} of
        {beam, Entry} -> validate_entrypoint(Entry);
        {<<"beam">>, Entry} -> validate_entrypoint(Entry);
        {Kind, _} -> {error, {unsupported_beamscale_runtime, Kind}}
    end;
beam_entrypoint(_) ->
    {error, invalid_runtime_descriptor}.

validate_entrypoint(Entry0) ->
    case valid_nonempty_text(Entry0) of
        false -> {error, invalid_beam_entrypoint};
        true ->
            Entry = to_binary(Entry0),
            case re:run(Entry, <<"^[A-Za-z0-9_]+:[A-Za-z0-9_]+/[0-9]+$">>, [{capture, none}]) of
                match -> {ok, Entry};
                nomatch -> {error, invalid_beam_entrypoint}
            end
    end.

normalize_method(Method) when is_atom(Method) -> normalize_method(atom_to_binary(Method, utf8));
normalize_method(Method) when is_list(Method) -> normalize_method(unicode:characters_to_binary(Method));
normalize_method(Method) when is_binary(Method), byte_size(Method) > 0, byte_size(Method) =< 16 ->
    Upper = unicode:characters_to_binary(string:uppercase(binary_to_list(Method))),
    case lists:member(Upper, [<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>, <<"PATCH">>,
                              <<"DELETE">>, <<"OPTIONS">>, <<"CONNECT">>, <<"TRACE">>, <<"ANY">>]) of
        true -> {ok, Upper};
        false -> {error, invalid_http_method}
    end;
normalize_method(_) -> {error, invalid_http_method}.

normalize_path(Path0) when is_list(Path0) -> normalize_path(unicode:characters_to_binary(Path0));
normalize_path(<<"/">> = Path) -> {ok, Path};
normalize_path(<<"/", _/binary>> = Path) when byte_size(Path) =< 4096 ->
    case valid_path_bytes(Path) andalso
         binary:match(Path, <<"?">>) =:= nomatch andalso
         binary:match(Path, <<"#">>) =:= nomatch andalso
         binary:match(Path, <<"//">>) =:= nomatch andalso
         binary:last(Path) =/= $/ of
        true -> {ok, Path};
        false -> {error, invalid_http_path}
    end;
normalize_path(_) -> {error, invalid_http_path}.

valid_path_bytes(Path) ->
    lists:all(
      fun(Byte) -> Byte >= 32 andalso Byte =/= 127 andalso Byte =/= $\\ end,
      binary_to_list(Path)).

validate_route_pattern(Path) ->
    Segments = split_path(Path),
    validate_pattern_segments(Segments, #{}, 1, length(Segments)).

validate_pattern_segments([], _Names, _Index, _Length) -> ok;
validate_pattern_segments([Segment | Rest], Names, Index, Length) ->
    case classify_pattern_segment(Segment) of
        {literal, _} ->
            validate_pattern_segments(Rest, Names, Index + 1, Length);
        {param, Name} ->
            validate_named_segment(Name, param, Rest, Names, Index, Length);
        {wildcard, Name} when Index =:= Length ->
            validate_named_segment(Name, wildcard, Rest, Names, Index, Length);
        {wildcard, _Name} ->
            {error, wildcard_must_be_terminal};
        invalid ->
            {error, invalid_route_parameter}
    end.

validate_named_segment(Name, _Kind, Rest, Names, Index, Length) ->
    case valid_parameter_name(Name) of
        false -> {error, invalid_route_parameter};
        true ->
            case maps:is_key(Name, Names) of
                true -> {error, {duplicate_route_parameter, Name}};
                false ->
                    validate_pattern_segments(Rest, maps:put(Name, true, Names), Index + 1, Length)
            end
    end.

classify_pattern_segment(<<":", Name/binary>>) when byte_size(Name) > 0 -> {param, Name};
classify_pattern_segment(<<"*", Name/binary>>) when byte_size(Name) > 0 -> {wildcard, Name};
classify_pattern_segment(<<":">>) -> invalid;
classify_pattern_segment(<<"*">>) -> invalid;
classify_pattern_segment(Segment) -> {literal, Segment}.

valid_parameter_name(Name) when byte_size(Name) =< 128 ->
    re:run(Name, <<"^[A-Za-z_][A-Za-z0-9_]*$">>, [{capture, none}]) =:= match;
valid_parameter_name(_) -> false.

canonical_shape(Path) ->
    Segments = split_path(Path),
    Canonical = [canonical_segment(S) || S <- Segments],
    <<"/", (join_segments(Canonical))/binary>>.

canonical_segment(<<":", _/binary>>) -> <<":">>;
canonical_segment(<<"*", _/binary>>) -> <<"*">>;
canonical_segment(Segment) -> Segment.

split_path(<<"/">>) -> [];
split_path(<<"/", Rest/binary>>) -> binary:split(Rest, <<"/">>, [global]).

join_segments([]) -> <<>>;
join_segments([First | Rest]) ->
    lists:foldl(fun(S, Acc) -> <<Acc/binary, "/", S/binary>> end, First, Rest).

valid_digest(Value) ->
    case maybe_binary(Value) of
        {ok, <<"sha256:", Hex/binary>>} when byte_size(Hex) =:= 64 ->
            lists:all(fun is_lower_hex/1, binary_to_list(Hex));
        _ -> false
    end.

is_lower_hex(C) when C >= $0, C =< $9 -> true;
is_lower_hex(C) when C >= $a, C =< $f -> true;
is_lower_hex(_) -> false.

valid_nonempty_text(Value) ->
    case maybe_binary(Value) of
        {ok, Bin} -> byte_size(Bin) > 0 andalso byte_size(Bin) =< 1024 andalso
                     binary:match(Bin, <<0>>) =:= nomatch;
        error -> false
    end.

maybe_binary(Value) when is_binary(Value) -> {ok, Value};
maybe_binary(Value) when is_list(Value) -> {ok, unicode:characters_to_binary(Value)};
maybe_binary(_) -> error.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_list(Value) -> unicode:characters_to_binary(Value);
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8).

maybe_put(_Key, undefined, Map) -> Map;
maybe_put(Key, Value, Map) -> Map#{Key => to_binary(Value)}.

value(Key, Map) ->
    case maps:find(Key, Map) of
        {ok, V} -> V;
        error -> maps:get(atom_to_binary(Key, utf8), Map, undefined)
    end.
