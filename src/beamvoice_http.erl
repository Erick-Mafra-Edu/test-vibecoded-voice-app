-module(beamvoice_http).
-export([start_link/0]).
start_link() ->
    Dispatch = cowboy_router:compile([{'_', [
        {"/health", beamvoice_health_handler, []},
        {"/ws", beamvoice_ws_handler, []}
    ]}]),
    Port = case os:getenv("PORT") of
        false -> application:get_env(beamvoice, port, 8080);
        Value -> list_to_integer(Value)
    end,
    cowboy:start_clear(beamvoice_listener, [{port, Port}], #{env => #{dispatch => Dispatch}}).
