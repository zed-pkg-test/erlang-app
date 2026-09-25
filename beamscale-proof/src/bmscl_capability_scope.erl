-module(bmscl_capability_scope).

-export([normalize_grants/1, names/1, install/1, grant/1, scope/1]).

-define(MAX_GRANTS, 8).
-define(MAX_HTTP_ORIGINS, 16).
-define(MAX_HTTP_REQUEST_BODY, 1024 * 1024).
-define(MAX_HTTP_RESPONSE_BODY, 4 * 1024 * 1024).

-spec normalize_grants(term()) -> [map()] | no_return().
normalize_grants(Grants) when is_list(Grants), length(Grants) =< ?MAX_GRANTS ->
    Normalized = [normalize_grant(Grant) || Grant <- Grants],
    Names = names(Normalized),
    case length(Names) =:= length(lists:usort(Names)) of
        true -> Normalized;
        false -> error(duplicate_capabilities)
    end;
normalize_grants(_) ->
    error(invalid_capabilities).

-spec names([map()]) -> [binary()].
names(Grants) when is_list(Grants) ->
    [maps:get(<<"name">>, Grant) || Grant <- Grants].

-spec install(map()) -> ok | {error, term()}.
install(Context) when is_map(Context) ->
    try
        Grants = normalize_grants(maps:get(<<"admitted_capability_grants">>, Context, [])),
        erlang:put({?MODULE, grants}, maps:from_list([
            {maps:get(<<"name">>, Grant), Grant} || Grant <- Grants
        ])),
        ok
    catch
        error:Reason -> {error, Reason}
    end;
install(_) ->
    {error, invalid_capability_context}.

-spec grant(binary()) -> {ok, map()} | {error, term()}.
grant(Name) when is_binary(Name) ->
    case erlang:get({?MODULE, grants}) of
        Grants when is_map(Grants) ->
            case maps:find(Name, Grants) of
                {ok, Grant} -> {ok, Grant};
                error -> {error, capability_scope_not_admitted}
            end;
        _ -> {error, capability_scope_not_installed}
    end;
grant(_) ->
    {error, invalid_capability_name}.

-spec scope(binary()) -> {ok, term()} | {error, term()}.
scope(Name) ->
    case grant(Name) of
        {ok, Grant} -> {ok, maps:get(<<"scope">>, Grant, undefined)};
        {error, Reason} -> {error, Reason}
    end.

normalize_grant(Grant) when is_map(Grant) ->
    Name = maps:get(<<"name">>, Grant),
    ok = validate_name(Name),
    ok = validate_grant_keys(Grant),
    ScopePresent = maps:is_key(<<"scope">>, Grant),
    Scope = maps:get(<<"scope">>, Grant, undefined),
    ok = validate_scope(Name, ScopePresent, Scope),
    case ScopePresent of
        true -> #{<<"name">> => Name, <<"scope">> => Scope};
        false -> #{<<"name">> => Name}
    end;
normalize_grant(_) ->
    error(invalid_capability_grant).

validate_grant_keys(Grant) ->
    Allowed = [<<"name">>, <<"scope">>],
    case [Key || Key <- maps:keys(Grant), not lists:member(Key, Allowed)] of
        [] -> ok;
        Extra -> error({unknown_capability_grant_keys, Extra})
    end.

validate_name(Name) when is_binary(Name), byte_size(Name) > 4, byte_size(Name) =< 128 ->
    case re:run(Name, <<"^ctx\\.[a-zA-Z0-9._-]+$">>, [{capture, none}]) of
        match -> ok;
        nomatch -> error({invalid_capability_name, Name})
    end;
validate_name(Name) ->
    error({invalid_capability_name, Name}).

validate_scope(<<"ctx.cluster">>, true, Scope) when is_map(Scope) ->
    require_exact_keys(Scope, [
        <<"same_cluster_only">>,
        <<"transport">>,
        <<"version_affinity">>,
        <<"methods">>,
        <<"max_request_body_bytes">>
    ]),
    true = maps:get(<<"same_cluster_only">>, Scope) =:= true,
    <<"http-semantics">> = maps:get(<<"transport">>, Scope),
    <<"inherit">> = maps:get(<<"version_affinity">>, Scope),
    Methods = lists:sort(maps:get(<<"methods">>, Scope)),
    [<<"GET">>, <<"HEAD">>] = Methods,
    0 = maps:get(<<"max_request_body_bytes">>, Scope),
    ok;
validate_scope(<<"ctx.http">>, true, Scope) when is_map(Scope) ->
    try validate_http_scope(Scope)
    catch
        error:_ -> error({invalid_capability_scope, <<"ctx.http">>})
    end;
validate_scope(<<"ctx.log">>, true, Scope) when is_map(Scope) ->
    require_exact_keys(Scope, [<<"sink">>, <<"application_state">>]),
    <<"tenant-observability">> = maps:get(<<"sink">>, Scope),
    false = maps:get(<<"application_state">>, Scope),
    ok;
validate_scope(Name, _Present, _Scope) -> error({invalid_capability_scope, Name}).

validate_http_scope(Scope) ->
    require_exact_keys(Scope, [
        <<"origins">>,
        <<"methods">>,
        <<"max_request_body_bytes">>,
        <<"max_response_body_bytes">>,
        <<"max_redirects">>,
        <<"public_network_only">>
    ]),
    Origins = maps:get(<<"origins">>, Scope),
    true = is_list(Origins) andalso length(Origins) > 0 andalso
           length(Origins) =< ?MAX_HTTP_ORIGINS,
    true = length(Origins) =:= length(lists:usort(Origins)),
    true = lists:all(fun valid_https_origin/1, Origins),
    Methods = lists:sort(maps:get(<<"methods">>, Scope)),
    [<<"DELETE">>, <<"GET">>, <<"HEAD">>, <<"OPTIONS">>,
     <<"PATCH">>, <<"POST">>, <<"PUT">>] = Methods,
    RequestMax = maps:get(<<"max_request_body_bytes">>, Scope),
    true = is_integer(RequestMax) andalso RequestMax >= 0 andalso
           RequestMax =< ?MAX_HTTP_REQUEST_BODY,
    ResponseMax = maps:get(<<"max_response_body_bytes">>, Scope),
    true = is_integer(ResponseMax) andalso ResponseMax > 0 andalso
           ResponseMax =< ?MAX_HTTP_RESPONSE_BODY,
    0 = maps:get(<<"max_redirects">>, Scope),
    true = maps:get(<<"public_network_only">>, Scope) =:= true,
    ok.

valid_https_origin(Origin) when is_binary(Origin), byte_size(Origin) =< 2048 ->
    try uri_string:parse(binary_to_list(Origin)) of
        Parsed when is_map(Parsed) ->
            Scheme = maps:get(scheme, Parsed, undefined),
            Host = maps:get(host, Parsed, undefined),
            Port = maps:get(port, Parsed, 443),
            Path = maps:get(path, Parsed, ""),
            Scheme =:= "https" andalso
            is_list(Host) andalso Host =/= [] andalso
            string:find(Host, ".") =/= nomatch andalso
            not lists:member($*, Host) andalso
            public_hostname(Host) andalso
            inet:parse_address(Host) =:= {error, einval} andalso
            is_integer(Port) andalso Port > 0 andalso Port =< 65535 andalso
            Path =:= "" andalso
            not maps:is_key(userinfo, Parsed) andalso
            not maps:is_key(query, Parsed) andalso
            not maps:is_key(fragment, Parsed);
        _ -> false
    catch
        _:_ -> false
    end;
valid_https_origin(_) -> false.

public_hostname(Host0) ->
    Host = strip_trailing_dot(string:lowercase(Host0)),
    Host =/= "localhost" andalso
    not lists:any(
      fun(Suffix) -> lists:suffix(Suffix, Host) end,
      [".localhost", ".local", ".internal", ".home.arpa"]).

strip_trailing_dot([]) -> [];
strip_trailing_dot(Host) ->
    case lists:last(Host) of
        $. -> lists:sublist(Host, length(Host) - 1);
        _ -> Host
    end.

require_exact_keys(Map, Expected0) ->
    Expected = lists:sort(Expected0),
    case lists:sort(maps:keys(Map)) of
        Expected -> ok;
        Actual -> error({invalid_capability_scope_keys, Expected, Actual})
    end.
