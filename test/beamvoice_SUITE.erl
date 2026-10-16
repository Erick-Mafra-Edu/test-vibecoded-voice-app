-module(beamvoice_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         registry_restart_preserves_room/1, websocket_origin_policy/1,
         metrics_render/1]).

all() -> [registry_restart_preserves_room, websocket_origin_policy, metrics_render].

init_per_suite(Config) ->
    application:load(beamvoice),
    application:set_env(beamvoice, port, 0),
    application:set_env(beamvoice, allow_insecure, true),
    {ok, _} = application:ensure_all_started(beamvoice),
    Config.

end_per_suite(_Config) ->
    application:stop(beamvoice),
    ok.

registry_restart_preserves_room(_Config) ->
    {ok, Room} = beamvoice_room_registry:get_or_create(<<"supervised">>),
    ok = beamvoice_room:join(Room, <<"alice">>, self()),
    Registry = whereis(beamvoice_room_registry),
    exit(Registry, kill),
    NewRegistry = wait_for_registry(Registry, 100),
    true = is_pid(NewRegistry),
    {ok, Room} = beamvoice_room_registry:get_or_create(<<"supervised">>),
    ok = beamvoice_room:leave(Room, <<"alice">>).

websocket_origin_policy(_Config) ->
    Port = ranch:get_port(beamvoice_listener),
    {ok, Denied} = handshake(Port, <<"https://evil.example">>),
    {match, _} = re:run(Denied, <<"HTTP/1\\.1 403">>),
    {ok, Allowed} = handshake(Port, <<"http://localhost:8080">>),
    {match, _} = re:run(Allowed, <<"HTTP/1\\.1 101">>).

metrics_render(_Config) ->
    Metrics = beamvoice_metrics:render(),
    {match, _} = re:run(Metrics, <<"beamvoice_beam_processes [0-9]+">>),
    case file:read_file("/sys/fs/cgroup/memory.current") of
        {ok, _} -> {match, _} = re:run(Metrics, <<"beamvoice_cgroup_memory_current_bytes [0-9]+">>);
        _ -> ok
    end.

handshake(Port, Origin) ->
    {ok, Socket} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 1000),
    Request = [<<"GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n",
                 "Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n",
                 "Sec-WebSocket-Version: 13\r\nOrigin: ">>, Origin, <<"\r\n\r\n">>],
    ok = gen_tcp:send(Socket, Request),
    Result = gen_tcp:recv(Socket, 0, 1000),
    gen_tcp:close(Socket),
    Result.

wait_for_registry(Old, Attempts) ->
    case whereis(beamvoice_room_registry) of
        undefined when Attempts > 0 -> timer:sleep(10), wait_for_registry(Old, Attempts - 1);
        Old when Attempts > 0 -> timer:sleep(10), wait_for_registry(Old, Attempts - 1);
        Pid -> Pid
    end.
