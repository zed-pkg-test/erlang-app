-module(bmscl_microvm_contract).

-export([issue/3, verify/3, tenant_from_context/1]).

-define(VERSION, 1).
-define(DEFAULT_TTL_SECONDS, 30).
-define(MAX_TTL_SECONDS, 300).

-spec issue(atom(), term(), map()) -> {ok, map()} | {error, term()}.
issue(Operation, TenantId0, Target) when is_atom(Operation), is_map(Target) ->
    case {normalize_tenant(TenantId0), signing_secret()} of
        {{ok, TenantId}, {ok, Secret}} ->
            Now = erlang:system_time(second),
            TTL = application:get_env(
                    bmscl_supervisor, microvm_contract_ttl_seconds,
                    ?DEFAULT_TTL_SECONDS),
            case valid_ttl(TTL) of
                false -> {error, invalid_microvm_contract_ttl};
                true ->
                    case bmscl_execution_policy:authority(Target) of
                        {error, Reason} ->
                            {error, Reason};
                        {ok, Authority} ->
                            Claims = #{
                                version => ?VERSION,
                                backend => firecracker,
                                operation => Operation,
                                tenant_id => TenantId,
                                deployment_id => maps:get(deployment_id, Target, undefined),
                                experimental_profile => bmscl_faas_profile:profile(Target),
                                execution_class => bmscl_faas_profile:execution_class(Target),
                                authority => Authority,
                                tenant_isolation => single_tenant_microvm,
                                issued_at => Now,
                                expires_at => Now + TTL,
                                nonce => crypto:strong_rand_bytes(16)
                            },
                            {ok, #{claims => Claims,
                                   signature => sign(Claims, Secret)}}
                    end
            end;
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, Reason}} -> {error, Reason}
    end;
issue(_, _, _) ->
    {error, invalid_microvm_contract_request}.

-spec verify(map(), atom(), term()) -> {ok, map()} | {error, term()}.
verify(Contract, ExpectedOperation, WorkerTenant0)
  when is_map(Contract), is_atom(ExpectedOperation) ->
    case {maps:find(claims, Contract),
          maps:find(signature, Contract),
          normalize_tenant(WorkerTenant0),
          signing_secret()} of
        {{ok, Claims}, {ok, Signature}, {ok, WorkerTenant}, {ok, Secret}}
          when is_map(Claims), is_binary(Signature) ->
            verify_claims(Claims, Signature, Secret, ExpectedOperation, WorkerTenant);
        {_, _, {error, Reason}, _} -> {error, Reason};
        {_, _, _, {error, Reason}} -> {error, Reason};
        _ -> {error, malformed_microvm_contract}
    end;
verify(_, _, _) ->
    {error, malformed_microvm_contract}.

tenant_from_context(Context) when is_map(Context) ->
    case maps:find(tenant_id, Context) of
        {ok, Tenant} -> normalize_tenant(Tenant);
        error ->
            case maps:find(<<"tenant_id">>, Context) of
                {ok, Tenant} -> normalize_tenant(Tenant);
                error -> {error, microvm_tenant_required}
            end
    end;
tenant_from_context(_) ->
    {error, microvm_tenant_required}.

verify_claims(Claims, Signature, Secret, ExpectedOperation, WorkerTenant) ->
    Now = erlang:system_time(second),
    ExpectedSig = sign(Claims, Secret),
    case secure_equal(Signature, ExpectedSig) of
        false -> {error, invalid_microvm_contract_signature};
        true ->
            case {maps:get(version, Claims, undefined),
                  maps:get(backend, Claims, undefined),
                  maps:get(operation, Claims, undefined),
                  maps:get(tenant_id, Claims, undefined),
                  maps:get(issued_at, Claims, undefined),
                  maps:get(expires_at, Claims, undefined)} of
                {?VERSION, firecracker, ExpectedOperation, WorkerTenant,
                 IssuedAt, ExpiresAt}
                  when is_integer(IssuedAt), is_integer(ExpiresAt),
                       ExpiresAt >= Now,
                       IssuedAt =< Now + 5,
                       ExpiresAt - IssuedAt =< ?MAX_TTL_SECONDS ->
                    {ok, Claims};
                {?VERSION, firecracker, Operation, _Tenant, _IssuedAt, _ExpiresAt}
                  when Operation =/= ExpectedOperation ->
                    {error, microvm_operation_mismatch};
                {?VERSION, firecracker, _Operation, Tenant, _IssuedAt, _ExpiresAt}
                  when Tenant =/= WorkerTenant ->
                    {error, microvm_tenant_mismatch};
                {?VERSION, firecracker, _Operation, _Tenant, _IssuedAt, ExpiresAt}
                  when is_integer(ExpiresAt), ExpiresAt < Now ->
                    {error, microvm_contract_expired};
                _ ->
                    {error, invalid_microvm_contract_claims}
            end
    end.

sign(Claims, Secret) ->
    crypto:mac(hmac, sha256, Secret, term_to_binary(Claims, [deterministic])).

signing_secret() ->
    case application:get_env(bmscl_supervisor, microvm_contract_secret, undefined) of
        Secret when is_binary(Secret), byte_size(Secret) >= 32 -> {ok, Secret};
        undefined -> {error, microvm_contract_secret_unavailable};
        _ -> {error, invalid_microvm_contract_secret}
    end.

valid_ttl(TTL) ->
    is_integer(TTL) andalso TTL >= 1 andalso TTL =< ?MAX_TTL_SECONDS.

normalize_tenant(Value) when is_binary(Value), byte_size(Value) > 0,
                           byte_size(Value) =< 256 ->
    case binary:match(Value, <<0>>) of
        nomatch -> {ok, Value};
        _ -> {error, invalid_microvm_tenant}
    end;
normalize_tenant(Value) when is_list(Value) ->
    normalize_tenant(unicode:characters_to_binary(Value));
normalize_tenant(_) ->
    {error, invalid_microvm_tenant}.

secure_equal(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    secure_equal(A, B, 0) =:= 0;
secure_equal(_, _) ->
    false.

secure_equal(<<>>, <<>>, Acc) -> Acc;
secure_equal(<<A, ARest/binary>>, <<B, BRest/binary>>, Acc) ->
    secure_equal(ARest, BRest, Acc bor (A bxor B)).
