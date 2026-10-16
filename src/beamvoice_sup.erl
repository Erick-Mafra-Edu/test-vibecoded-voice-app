-module(beamvoice_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    Metrics = #{id => beamvoice_metrics, start => {beamvoice_metrics, start_link, []}},
    RoomSup = #{id => beamvoice_room_sup,
                start => {beamvoice_room_sup, start_link, []},
                restart => permanent, shutdown => 5000,
                type => supervisor, modules => [beamvoice_room_sup]},
    Registry = #{id => beamvoice_room_registry,
                 start => {beamvoice_room_registry, start_link, []},
                 restart => permanent, shutdown => 5000,
                 type => worker, modules => [beamvoice_room_registry]},
    Http = #{id => beamvoice_http,
             start => {beamvoice_http, start_link, []},
             restart => permanent, shutdown => 5000,
             type => worker, modules => [beamvoice_http]},
    {ok, {{one_for_one, 5, 10}, [Metrics, RoomSup, Registry, Http]}}.
