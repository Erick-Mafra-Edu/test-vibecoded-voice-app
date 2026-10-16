-module(beamvoice_room_registry_tests).
-include_lib("eunit/include/eunit.hrl").

registry_recovers_existing_rooms_test() ->
    State = start(),
    try
         {ok, Room} = beamvoice_room_registry:get_or_create(<<"kept">>),
         ok = beamvoice_room:join(Room, <<"alice">>, self()),
         ok = gen_server:stop(beamvoice_room_registry),
         {ok, _} = beamvoice_room_registry:start_link(),
         ?assertEqual({ok, Room}, beamvoice_room_registry:get_or_create(<<"kept">>)),
         ok = beamvoice_room:leave(Room, <<"alice">>)
    after
        stop(State)
    end.

room_limit_and_cleanup_test() ->
    State = start(),
    try
         application:set_env(beamvoice, max_rooms, 1),
         {ok, Room} = beamvoice_room_registry:get_or_create(<<"one">>),
         ok = beamvoice_room:join(Room, <<"alice">>, self()),
         ?assertEqual({error, room_limit}, beamvoice_room_registry:get_or_create(<<"two">>)),
         ok = beamvoice_room:leave(Room, <<"alice">>),
         wait_until(fun() -> beamvoice_room_registry:list() =:= [] end, 50),
         ?assertMatch({ok, _}, beamvoice_room_registry:get_or_create(<<"two">>))
    after
        stop(State)
    end.

start() ->
    PreviousMax = application:get_env(beamvoice, max_rooms),
    PreviousTtl = application:get_env(beamvoice, room_empty_ttl_ms),
    application:set_env(beamvoice, max_rooms, 100),
    application:set_env(beamvoice, room_empty_ttl_ms, 10),
    {ok, Sup} = beamvoice_room_sup:start_link(),
    {ok, Registry} = beamvoice_room_registry:start_link(),
    {Sup, Registry, PreviousMax, PreviousTtl}.

stop({Sup, _Registry, PreviousMax, PreviousTtl}) ->
    case whereis(beamvoice_room_registry) of
        undefined -> ok;
        Registry -> gen_server:stop(Registry)
    end,
    Ref = monitor(process, Sup),
    unlink(Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Ref, process, Sup, shutdown} -> ok after 1000 -> ?assert(false) end,
    restore_env(max_rooms, PreviousMax),
    restore_env(room_empty_ttl_ms, PreviousTtl).

wait_until(Check, Attempts) ->
    case Check() of
        true -> ok;
        false when Attempts > 0 -> timer:sleep(10), wait_until(Check, Attempts - 1);
        false -> ?assert(false)
    end.

restore_env(Key, {ok, Value}) -> application:set_env(beamvoice, Key, Value);
restore_env(Key, undefined) -> application:unset_env(beamvoice, Key).
