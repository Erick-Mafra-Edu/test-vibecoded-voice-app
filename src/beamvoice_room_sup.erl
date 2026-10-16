-module(beamvoice_room_sup).
-behaviour(supervisor).
-export([start_link/0, start_room/1, rooms/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_room(Id) ->
    Child = #{id => {beamvoice_room, Id},
              start => {beamvoice_room, start_link, [Id]},
              restart => temporary, shutdown => 5000,
              type => worker, modules => [beamvoice_room]},
    supervisor:start_child(?MODULE, Child).

rooms() -> supervisor:which_children(?MODULE).

init([]) -> {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
