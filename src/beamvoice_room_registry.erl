-module(beamvoice_room_registry).
-behaviour(gen_server).
-export([start_link/0, get_or_create/1, list/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
get_or_create(Id) when is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 64 ->
    gen_server:call(?MODULE, {get_or_create, Id});
get_or_create(_) -> {error, invalid_room_id}.
list() -> gen_server:call(?MODULE, list).
init([]) -> {ok, #{}}.
handle_call({get_or_create, Id}, _From, Rooms) ->
    case maps:find(Id, Rooms) of
        {ok, {Pid, _Ref}} when is_pid(Pid) -> {reply, {ok, Pid}, Rooms};
        error ->
            {ok, Pid} = beamvoice_room:start_link(Id),
            Ref = erlang:monitor(process, Pid),
            {reply, {ok, Pid}, Rooms#{Id => {Pid, Ref}}}
    end;
handle_call(list, _From, Rooms) -> {reply, maps:keys(Rooms), Rooms};
handle_call(_, _From, Rooms) -> {reply, {error, bad_request}, Rooms}.
handle_cast(_, Rooms) -> {noreply, Rooms}.
handle_info({'DOWN', Ref, process, _Pid, _Reason}, Rooms) ->
    {noreply, maps:filter(fun(_Id, {_P, R}) -> R =/= Ref end, Rooms)};
handle_info(_, Rooms) -> {noreply, Rooms}.
terminate(_Reason, _Rooms) -> ok.
code_change(_Old, Rooms, _Extra) -> {ok, Rooms}.
