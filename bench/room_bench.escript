#!/usr/bin/env escript
%%! -pa _build/default/lib/beamvoice/ebin

main(_) ->
    io:format("clients,operations,p50_us,p95_us,p99_us,max_us,room_mailbox,memory_bytes~n"),
    [run(Clients) || Clients <- [2, 6, 12, 24]].

run(Clients) ->
    {ok, Room} = beamvoice_room:start_link(<<"benchmark">>),
    Parent = self(),
    Workers = [spawn(fun() -> worker(Parent, Room, integer_to_binary(N)) end)
               || N <- lists:seq(1, Clients)],
    [receive {ready, Pid} -> ok end || Pid <- Workers],
    [Pid ! go || Pid <- Workers],
    Samples = lists:append([receive {done, Pid, Times} -> Times end || Pid <- Workers]),
    {message_queue_len, Mailbox} = process_info(Room, message_queue_len),
    {memory, Memory} = process_info(Room, memory),
    Sorted = lists:sort(Samples),
    io:format("~p,~p,~p,~p,~p,~p,~p,~p~n",
              [Clients, length(Sorted), percentile(Sorted, 50), percentile(Sorted, 95),
               percentile(Sorted, 99), lists:last(Sorted), Mailbox, Memory]),
    gen_server:stop(Room),
    [Pid ! stop || Pid <- Workers].

worker(Parent, Room, User) ->
    ok = beamvoice_room:join(Room, User, self()),
    Parent ! {ready, self()},
    receive go -> ok end,
    Times = [timed_members(Room) || _ <- lists:seq(1, 100)],
    Parent ! {done, self(), Times},
    receive stop -> ok end.

timed_members(Room) ->
    Start = erlang:monotonic_time(microsecond),
    _ = beamvoice_room:members(Room),
    erlang:monotonic_time(microsecond) - Start.

percentile(Values, Percent) ->
    lists:nth(max(1, (length(Values) * Percent + 99) div 100), Values).
