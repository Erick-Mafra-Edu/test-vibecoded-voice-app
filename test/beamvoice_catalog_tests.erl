-module(beamvoice_catalog_tests).
-include_lib("eunit/include/eunit.hrl").

catalog_persists_and_filters_test() ->
    Path = filename:join("/tmp", "beamvoice-catalog-" ++
                                integer_to_list(erlang:unique_integer([positive])) ++ ".json"),
    application:set_env(beamvoice, catalog_file, Path),
    try
        {ok, Pid} = beamvoice_catalog:start_link(),
        ?assertEqual(ok, beamvoice_catalog:create_server(<<"lab">>, <<"Lab">>)),
        ?assertEqual(ok, beamvoice_catalog:create_channel(<<"lab">>, <<"general">>, <<"General">>)),
        ?assertEqual(ok, beamvoice_catalog:rename_channel(<<"lab">>, <<"general">>, <<"Voice">>)),
        ?assertEqual(true, beamvoice_catalog:room_exists(<<"lab/general">>)),
        ?assert(beamvoice_auth:allowed(#{rooms => [<<"lab">>]}, <<"lab/general">>)),
        ?assertNot(beamvoice_auth:allowed(#{rooms => [<<"lab">>]}, <<"lab/other">>)),
        ?assertEqual([], beamvoice_catalog:list(#{rooms => [<<"other">>]})),
        [Server] = beamvoice_catalog:list(#{rooms => [<<"lab">>]}),
        ?assertEqual(<<"Voice">>, maps:get(name, hd(maps:get(channels, Server)))),
        gen_server:stop(Pid),
        {ok, Restarted} = beamvoice_catalog:start_link(),
        ?assertEqual(true, beamvoice_catalog:room_exists(<<"lab/general">>)),
        gen_server:stop(Restarted)
    after
        application:unset_env(beamvoice, catalog_file),
        file:delete(Path)
    end.
