-module(beamvoice_room_registry).
-behaviour(gen_server).
-export([start_link/0, get_or_create/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
get_or_create(Id) when is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 64 ->
    gen_server:call(?MODULE, {get_or_create, Id}, 2000);
get_or_create(_) -> {error, invalid_room_id}.
list() -> gen_server:call(?MODULE, list, 2000).
init([]) ->
    Rooms = maps:from_list([{Id, {Pid, erlang:monitor(process, Pid)}}
                            || {{beamvoice_room, Id}, Pid, worker, _} <- beamvoice_room_sup:rooms(),
                               is_pid(Pid)]),
    {ok, Rooms}.
handle_call({get_or_create, Id}, _From, Rooms) ->
    case maps:find(Id, Rooms) of
        {ok, {Pid, _Ref}} when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {reply, {ok, Pid}, Rooms};
                false -> create_room(Id, maps:remove(Id, Rooms))
            end;
        error -> create_room(Id, Rooms)
    end;
handle_call(list, _From, Rooms) -> {reply, maps:keys(Rooms), Rooms};
handle_call(_, _From, Rooms) -> {reply, {error, bad_request}, Rooms}.
handle_cast(_, Rooms) -> {noreply, Rooms}.
handle_info({'DOWN', Ref, process, _Pid, _Reason}, Rooms) ->
    {noreply, maps:filter(fun(_Id, {_P, R}) -> R =/= Ref end, Rooms)};
handle_info(_, Rooms) -> {noreply, Rooms}.
terminate(_Reason, _Rooms) -> ok.
code_change(_Old, Rooms, _Extra) -> {ok, Rooms}.

create_room(Id, Rooms) ->
    case map_size(Rooms) >= application:get_env(beamvoice, max_rooms, 100) of
        true -> {reply, {error, room_limit}, Rooms};
        false ->
            case beamvoice_room_sup:start_room(Id) of
                {ok, Pid} -> monitor_room(Id, Pid, Rooms);
                {error, {already_started, Pid}} -> monitor_room(Id, Pid, Rooms);
                {error, Reason} -> {reply, {error, Reason}, Rooms}
            end
    end.

monitor_room(Id, Pid, Rooms) ->
    Ref = erlang:monitor(process, Pid),
    {reply, {ok, Pid}, Rooms#{Id => {Pid, Ref}}}.
