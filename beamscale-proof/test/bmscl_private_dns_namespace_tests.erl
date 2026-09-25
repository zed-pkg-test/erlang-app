-module(bmscl_private_dns_namespace_tests).

-include_lib("eunit/include/eunit.hrl").

private_dns_namespaces_are_rejected_at_admission_test() ->
    Base = #{
        <<"methods">> => [<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PUT">>,
                         <<"PATCH">>, <<"DELETE">>, <<"OPTIONS">>],
        <<"max_request_body_bytes">> => 1048576,
        <<"max_response_body_bytes">> => 4194304,
        <<"max_redirects">> => 0,
        <<"public_network_only">> => true
    },
    lists:foreach(fun(Origin) ->
        ?assertError(
           {invalid_capability_scope, <<"ctx.http">>},
           bmscl_capability_scope:normalize_grants([
               #{<<"name">> => <<"ctx.http">>,
                 <<"scope">> => Base#{<<"origins">> => [Origin]}}
           ]))
    end, [
        <<"https://metadata.google.internal">>,
        <<"https://service.internal">>,
        <<"https://printer.local">>,
        <<"https://router.home.arpa">>,
        <<"https://foo.localhost">>,
        <<"https://SERVICE.INTERNAL.">>
    ]),
    ?assertMatch(
       [#{<<"name">> := <<"ctx.http">>}],
       bmscl_capability_scope:normalize_grants([
           #{<<"name">> => <<"ctx.http">>,
             <<"scope">> => Base#{<<"origins">> => [<<"https://api.example.com">>]}}
       ])).
