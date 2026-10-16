-module(beamvoice_auth_tests).
-include_lib("eunit/include/eunit.hrl").

identity_and_acl_test() ->
    Token = binary:copy(<<"X">>, 40),
    try
        application:set_env(beamvoice, credentials,
            [#{<<"token">> => Token, <<"user">> => <<"alice">>, <<"rooms">> => [<<"private">>]}]),
        ok = beamvoice_auth:load(),
        {ok, Claims} = beamvoice_auth:authenticate(Token),
        ?assertEqual(<<"alice">>, maps:get(user, Claims)),
        ?assert(beamvoice_auth:allowed(Claims, <<"private">>)),
        ?assertNot(beamvoice_auth:allowed(Claims, <<"other">>)),
        ?assertEqual({error, unauthorized}, beamvoice_auth:authenticate(binary:copy(<<"Y">>, 40))),
        ?assertEqual({error, unauthorized}, beamvoice_auth:authenticate(<<>>))
    after
        application:unset_env(beamvoice, credentials),
        persistent_term:erase(beamvoice_auth)
    end.
