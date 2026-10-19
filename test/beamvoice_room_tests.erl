-module(beamvoice_room_tests).
-include_lib("eunit/include/eunit.hrl").
room_lifecycle_test() ->
    Previous = application:get_env(beamvoice, room_empty_ttl_ms),
    application:set_env(beamvoice, room_empty_ttl_ms, 10),
    try
        {ok, Room} = beamvoice_room:start_link(<<"test">>),
        Ref = monitor(process, Room),
        ?assertEqual([], beamvoice_room:members(Room)),
        ?assertEqual(ok, beamvoice_room:join(Room, <<"alice">>, self())),
        {ok, Key} = beamvoice_room:key(Room, <<"alice">>, self()),
        ?assertEqual(32, byte_size(base64:decode(Key))),
        ?assertEqual({error, not_in_room}, beamvoice_room:key(Room, <<"bob">>, self())),
        ?assertEqual({error, already_joined}, beamvoice_room:join(Room, <<"alice">>, self())),
        ?assertEqual([<<"alice">>], beamvoice_room:members(Room)),
        ?assertEqual(ok, beamvoice_room:leave(Room, <<"alice">>)),
        ?assertEqual({error, not_in_room}, beamvoice_room:key(Room, <<"alice">>, self())),
        receive {'DOWN', Ref, process, Room, normal} -> ok after 1000 -> ?assert(false) end
    after
        restore_env(room_empty_ttl_ms, Previous)
    end.

room_key_is_shared_only_with_members_test() ->
    {ok, Room} = beamvoice_room:start_link(<<"key-test">>),
    Peer = spawn(fun wait/0),
    try
        ok = beamvoice_room:join(Room, <<"alice">>, self()),
        ok = beamvoice_room:join(Room, <<"bob">>, Peer),
        {ok, Key} = beamvoice_room:key(Room, <<"alice">>, self()),
        ?assertEqual({ok, Key}, beamvoice_room:key(Room, <<"bob">>, Peer)),
        ?assertEqual({error, not_in_room}, beamvoice_room:key(Room, <<"bob">>, self())),
        {ok, OtherRoom} = beamvoice_room:start_link(<<"other-key-test">>),
        try
            ok = beamvoice_room:join(OtherRoom, <<"alice">>, self()),
            {ok, OtherKey} = beamvoice_room:key(OtherRoom, <<"alice">>, self()),
            ?assertNotEqual(Key, OtherKey)
        after gen_server:stop(OtherRoom) end
    after
        exit(Peer, kill),
        gen_server:stop(Room)
    end.
room_disconnect_test() ->
    Previous = application:get_env(beamvoice, room_empty_ttl_ms),
    application:set_env(beamvoice, room_empty_ttl_ms, 10),
    try
        {ok, Room} = beamvoice_room:start_link(<<"disconnect">>),
        Ref = monitor(process, Room),
        Pid = spawn(fun() -> receive after infinity -> ok end end),
        ok = beamvoice_room:join(Room, <<"bob">>, Pid),
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Room, normal} -> ok after 1000 -> ?assert(false) end
    after
        restore_env(room_empty_ttl_ms, Previous)
    end.

room_member_limit_test() ->
    Previous = application:get_env(beamvoice, max_room_members),
    application:set_env(beamvoice, max_room_members, 2),
    try
        {ok, Room} = beamvoice_room:start_link(<<"limited">>),
        Pids = [spawn(fun wait/0) || _ <- lists:seq(1, 3)],
        [P1, P2, P3] = Pids,
        ?assertEqual(ok, beamvoice_room:join(Room, <<"one">>, P1)),
        ?assertEqual(ok, beamvoice_room:join(Room, <<"two">>, P2)),
        ?assertEqual({error, room_full}, beamvoice_room:join(Room, <<"three">>, P3)),
        ?assertEqual(2, length(beamvoice_room:members(Room))),
        [exit(Pid, kill) || Pid <- Pids]
    after
        restore_env(max_room_members, Previous)
    end.

concurrent_join_test() ->
    {ok, Room} = beamvoice_room:start_link(<<"concurrent">>),
    Parent = self(),
    Pids = [spawn(fun() ->
                      receive go ->
                          Parent ! {joined, beamvoice_room:join(Room, integer_to_binary(N), self())},
                          wait()
                      end
                  end) || N <- lists:seq(1, 24)],
    [Pid ! go || Pid <- Pids],
    [?assertEqual(ok, receive {joined, Result} -> Result after 1000 -> timeout end)
     || _ <- Pids],
    ?assertEqual(24, length(beamvoice_room:members(Room))),
    [exit(Pid, kill) || Pid <- Pids].

invalid_member_test() ->
    {ok, Room} = beamvoice_room:start_link(<<"invalid">>),
    ?assertEqual({error, invalid_member}, beamvoice_room:join(Room, <<>>, self())),
    gen_server:stop(Room).

chat_is_room_scoped_test() ->
    {ok, Room} = beamvoice_room:start_link(<<"chat">>),
    Peer = spawn(fun() -> receive stop -> ok end end),
    try
        ok = beamvoice_room:join(Room, <<"alice">>, self()),
        ok = beamvoice_room:join(Room, <<"bob">>, Peer),
        ?assertEqual({error, not_in_room}, beamvoice_room:chat(Room, <<"bob">>, self(), <<"forged">>)),
        ok = beamvoice_room:chat(Room, <<"alice">>, self(), <<"hello">>),
        receive {signaling, #{type := chat, from := <<"alice">>, content := <<"hello">>}} -> ok
        after 1000 -> ?assert(false) end
    after
        Peer ! stop,
        gen_server:stop(Room)
    end.

room_rejoin_during_cleanup_test() ->
    Previous = application:get_env(beamvoice, room_empty_ttl_ms),
    application:set_env(beamvoice, room_empty_ttl_ms, 100),
    try
        {ok, Room} = beamvoice_room:start_link(<<"rejoin">>),
        ok = beamvoice_room:join(Room, <<"alice">>, self()),
        ok = beamvoice_room:leave(Room, <<"alice">>),
        ok = beamvoice_room:join(Room, <<"bob">>, self()),
        timer:sleep(120),
        ?assertEqual([<<"bob">>], beamvoice_room:members(Room)),
        gen_server:stop(Room)
    after
        restore_env(room_empty_ttl_ms, Previous)
    end.

wait() -> receive stop -> ok end.

restore_env(Key, {ok, Value}) -> application:set_env(beamvoice, Key, Value);
restore_env(Key, undefined) -> application:unset_env(beamvoice, Key).
