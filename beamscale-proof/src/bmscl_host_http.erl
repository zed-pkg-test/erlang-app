-module(bmscl_host_http).

-export([request/5]).

-define(MAX_URL_BYTES, 8192).
-define(MAX_HEADERS, 128).
-define(MAX_HEADER_NAME_BYTES, 128).
-define(MAX_HEADER_VALUE_BYTES, 8192).

-spec request(term(), binary(), binary(), list(), binary()) ->
    {ok, term()} | {error, binary()}.
request(Capability, Method, Url, Headers, Body)
  when is_binary(Method), is_binary(Url), is_list(Headers), is_binary(Body) ->
    case authorize(Capability) of
        {error, _} -> {error, <<"http_capability_denied">>};
        {ok, Meta} ->
            case broker_scope(<<"ctx.http">>) of
                {error, _} -> {error, <<"http_scope_unavailable">>};
                {ok, Scope} -> request_scoped(Method, Url, Headers, Body, Scope, Meta)
            end
    end;
request(_, _, _, _, _) ->
    {error, <<"http_request_invalid">>}.

authorize({http_capability, Token}) when is_binary(Token) ->
    bmscl_authority_broker:authorize(self(), <<"ctx.http">>, Token);
authorize(_) ->
    {error, invalid_capability_shape}.

broker_scope(Name) ->
    case bmscl_authority_broker:grant(self(), Name) of
        {ok, Grant} -> {ok, maps:get(<<"scope">>, Grant, undefined)};
        Error -> Error
    end.

request_scoped(Method, Url, Headers, Body, Scope, Meta) ->
    case validate_request(Method, Url, Headers, Body, Scope) of
        {error, Reason} -> {error, Reason};
        {ok, NormalizedHeaders} ->
            case application:get_env(bmscl_supervisor, http_provider_module, undefined) of
                undefined -> {error, <<"http_provider_unavailable">>};
                Provider when is_atom(Provider) ->
                    ProviderScope = harden_provider_scope(Scope),
                    try Provider:request(Method, Url, NormalizedHeaders, Body, ProviderScope, Meta) of
                        {ok, {response, Status, ResponseHeaders, ResponseBody}} = Ok
                          when is_integer(Status), Status >= 100, Status =< 599,
                               is_list(ResponseHeaders), is_binary(ResponseBody) ->
                            case byte_size(ResponseBody) =<
                                 maps:get(<<"max_response_body_bytes">>, Scope) of
                                true -> Ok;
                                false -> {error, <<"http_response_too_large">>}
                            end;
                        {error, Reason} when is_binary(Reason) -> {error, Reason};
                        _ -> {error, <<"http_provider_invalid_response">>}
                    catch
                        _:_ -> {error, <<"http_provider_failed">>}
                    end
            end
    end.

validate_request(Method, Url, Headers, Body, Scope) when is_map(Scope) ->
    case valid_security_scope(Scope) of
        false -> {error, <<"http_scope_insecure">>};
        true -> validate_request_secure(Method, Url, Headers, Body, Scope)
    end.

validate_request_secure(Method, Url, Headers, Body, Scope) ->
    Methods = maps:get(<<"methods">>, Scope, []),
    RequestMax = maps:get(<<"max_request_body_bytes">>, Scope, -1),
    case lists:member(Method, Methods) andalso allowed_method(Method) of
        false -> {error, <<"http_method_denied">>};
        true when byte_size(Body) > RequestMax -> {error, <<"http_request_too_large">>};
        true ->
            case allowed_url(Url, Scope) of
                false -> {error, <<"http_origin_denied">>};
                true -> normalize_headers(Headers)
            end
    end.

valid_security_scope(Scope) ->
    maps:get(<<"public_network_only">>, Scope, false) =:= true andalso
    maps:get(<<"max_redirects">>, Scope, -1) =:= 0.

harden_provider_scope(Scope) ->
    Scope#{
        <<"public_network_only">> => true,
        <<"deny_private_networks">> => true,
        <<"max_redirects">> => 0
    }.

allowed_method(<<"GET">>) -> true;
allowed_method(<<"HEAD">>) -> true;
allowed_method(<<"POST">>) -> true;
allowed_method(<<"PUT">>) -> true;
allowed_method(<<"PATCH">>) -> true;
allowed_method(<<"DELETE">>) -> true;
allowed_method(<<"OPTIONS">>) -> true;
allowed_method(_) -> false.

allowed_url(Url, Scope) when byte_size(Url) > 0, byte_size(Url) =< ?MAX_URL_BYTES ->
    case public_destination_literal(Url) of
        false -> false;
        true ->
            case canonical_origin(Url) of
                {ok, Origin} ->
                    AllowedOrigins = maps:get(<<"origins">>, Scope, []),
                    lists:any(fun(Allowed) ->
                        case canonical_origin(Allowed) of
                            {ok, Origin} -> true;
                            _ -> false
                        end
                    end, AllowedOrigins);
                _ -> false
            end
    end;
allowed_url(_, _) -> false.

public_destination_literal(Value) when is_binary(Value) ->
    try uri_string:parse(binary_to_list(Value)) of
        Parsed when is_map(Parsed) ->
            case maps:get(host, Parsed, undefined) of
                Host when is_list(Host), Host =/= [] -> public_host(Host);
                _ -> false
            end;
        _ -> false
    catch
        _:_ -> false
    end.

public_host(Host0) ->
    Host = strip_trailing_dot(string:lowercase(Host0)),
    case reserved_hostname(Host) of
        true -> false;
        false ->
            case inet:parse_address(Host) of
                {ok, Address} -> public_ip(Address);
                {error, _} -> true
            end
    end.

strip_trailing_dot([]) -> [];
strip_trailing_dot(Host) ->
    case lists:last(Host) of
        $. -> lists:sublist(Host, length(Host) - 1);
        _ -> Host
    end.

reserved_hostname("localhost") -> true;
reserved_hostname("metadata") -> true;
reserved_hostname("metadata.google.internal") -> true;
reserved_hostname("instance-data") -> true;
reserved_hostname(Host) ->
    lists:any(
      fun(Suffix) -> lists:suffix(Suffix, Host) end,
      [".localhost", ".local", ".internal", ".home.arpa"]).

public_ip({A, _, _, _}) when A =:= 0; A =:= 10; A =:= 127 -> false;
public_ip({100, B, _, _}) when B >= 64, B =< 127 -> false;
public_ip({169, 254, _, _}) -> false;
public_ip({172, B, _, _}) when B >= 16, B =< 31 -> false;
public_ip({192, 168, _, _}) -> false;
public_ip({198, B, _, _}) when B =:= 18; B =:= 19 -> false;
public_ip({A, _, _, _}) when A >= 224 -> false;
public_ip({_, _, _, _}) -> true;
public_ip({0, 0, 0, 0, 0, 0, 0, 0}) -> false;
public_ip({0, 0, 0, 0, 0, 0, 0, 1}) -> false;
public_ip({0, 0, 0, 0, 0, 16#ffff, G, H}) ->
    public_ip({G bsr 8, G band 16#ff, H bsr 8, H band 16#ff});
public_ip({A, _, _, _, _, _, _, _}) when (A band 16#fe00) =:= 16#fc00 -> false;
public_ip({A, _, _, _, _, _, _, _}) when (A band 16#ffc0) =:= 16#fe80 -> false;
public_ip({A, _, _, _, _, _, _, _}) when (A band 16#ff00) =:= 16#ff00 -> false;
public_ip({_, _, _, _, _, _, _, _}) -> true;
public_ip(_) -> false.

canonical_origin(Value) when is_binary(Value) ->
    try uri_string:parse(binary_to_list(Value)) of
        Parsed when is_map(Parsed) ->
            Scheme = maps:get(scheme, Parsed, undefined),
            Host = maps:get(host, Parsed, undefined),
            Port = maps:get(port, Parsed, 443),
            case Scheme =:= "https" andalso is_list(Host) andalso Host =/= [] andalso
                 is_integer(Port) andalso Port > 0 andalso Port =< 65535 andalso
                 not maps:is_key(userinfo, Parsed) of
                true ->
                    {ok, unicode:characters_to_binary(
                        io_lib:format("https://~s:~p", [string:lowercase(Host), Port]))};
                false -> error
            end;
        _ -> error
    catch
        _:_ -> error
    end.

normalize_headers(Headers) when length(Headers) =< ?MAX_HEADERS ->
    normalize_headers(Headers, []);
normalize_headers(_) -> {error, <<"http_headers_invalid">>}.

normalize_headers([], Acc) -> {ok, lists:reverse(Acc)};
normalize_headers([{Name, Value} | Rest], Acc)
  when is_binary(Name), is_binary(Value),
       byte_size(Name) > 0, byte_size(Name) =< ?MAX_HEADER_NAME_BYTES,
       byte_size(Value) =< ?MAX_HEADER_VALUE_BYTES ->
    case valid_header_name(Name) andalso valid_header_value(Value) andalso
         not forbidden_header(Name) of
        true -> normalize_headers(Rest, [{Name, Value} | Acc]);
        false -> {error, <<"http_header_denied">>}
    end;
normalize_headers(_, _) -> {error, <<"http_headers_invalid">>}.

valid_header_name(Name) ->
    lists:all(fun(Byte) ->
        (Byte >= $a andalso Byte =< $z) orelse
        (Byte >= $0 andalso Byte =< $9) orelse Byte =:= $-
    end, binary_to_list(Name)).

valid_header_value(Value) ->
    binary:match(Value, <<"\r">>) =:= nomatch andalso
    binary:match(Value, <<"\n">>) =:= nomatch andalso
    binary:match(Value, <<0>>) =:= nomatch.

forbidden_header(<<"host">>) -> true;
forbidden_header(<<"connection">>) -> true;
forbidden_header(<<"proxy-authorization">>) -> true;
forbidden_header(<<"proxy-authenticate">>) -> true;
forbidden_header(<<"transfer-encoding">>) -> true;
forbidden_header(<<"content-length">>) -> true;
forbidden_header(<<"upgrade">>) -> true;
forbidden_header(<<"te">>) -> true;
forbidden_header(_) -> false.
