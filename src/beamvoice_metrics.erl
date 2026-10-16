-module(beamvoice_metrics).
-behaviour(gen_server).
-export([start_link/0, init/1, handle_call/3, handle_cast/2, inc/1, render/0]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
init([]) ->
    ets:new(?MODULE, [named_table, public, set, {write_concurrency, true}]),
    {ok, #{}}.
handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
inc(Name) when Name =:= route_switch_total; Name =:= route_switch_failure_total;
               Name =:= rtp_packets_received_total; Name =:= rtp_packets_forwarded_total;
               Name =:= rtp_packets_dropped_total ->
    try ets:update_counter(?MODULE, Name, {2, 1}, {Name, 0}) catch error:badarg -> ok end.
render() ->
    Counters = ets:tab2list(?MODULE),
    Rooms = try length(beamvoice_room_registry:list()) catch exit:_ -> 0 end,
    iolist_to_binary([["beamvoice_", atom_to_list(K), " ", integer_to_list(V), "\n"]
                     || {K,V} <- [{active_rooms, Rooms}, {beam_processes, erlang:system_info(process_count)},
                                   {memory_bytes, erlang:memory(total)} | cgroup() ++ Counters]]).

cgroup() ->
    Cpu = case file:read_file("/sys/fs/cgroup/cpu.stat") of
        {ok, Data} ->
            case [V || <<"usage_usec ", V/binary>> <- binary:split(Data, <<"\n">>, [global])] of
                [V | _] -> [{cgroup_cpu_usage_usec, binary_to_integer(V)}];
                [] -> []
            end;
        _ -> []
    end,
    Memory = case file:read_file("/sys/fs/cgroup/memory.current") of
        {ok, Data2} -> [{cgroup_memory_current_bytes,
                         binary_to_integer(hd(binary:split(Data2, <<"\n">>, [global])))}];
        _ -> []
    end,
    Cpu ++ Memory.
