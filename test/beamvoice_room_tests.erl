-module(beamvoice_room_tests).
-include_lib("eunit/include/eunit.hrl").
room_lifecycle_test() ->
    {ok, Room} = beamvoice_room:start_link(<<"test">>),
    ?assertEqual([], beamvoice_room:members(Room)),
    ?assertEqual(ok, beamvoice_room:join(Room, <<"alice">>, self())),
    ?assertEqual({error, already_joined}, beamvoice_room:join(Room, <<"alice">>, self())),
    ?assertEqual([<<"alice">>], beamvoice_room:members(Room)),
    ?assertEqual(ok, beamvoice_room:leave(Room, <<"alice">>)),
    ?assertEqual([], beamvoice_room:members(Room)),
    gen_server:stop(Room).
room_disconnect_test() ->
    {ok, Room} = beamvoice_room:start_link(<<"disconnect">>),
    Pid = spawn(fun() -> receive after infinity -> ok end end),
    ok = beamvoice_room:join(Room, <<"bob">>, Pid),
    exit(Pid, kill),
    timer:sleep(30),
    ?assertEqual([], beamvoice_room:members(Room)),
    gen_server:stop(Room).
