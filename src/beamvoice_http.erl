-module(beamvoice_http).
-export([start_link/0]).
start_link() ->
    Dispatch = cowboy_router:compile([{'_', [
        {"/health", beamvoice_health_handler, []},
        {"/ws", beamvoice_ws_handler, []}
    ]}]),
    Port = port(),
    MaxConnections = application:get_env(beamvoice, max_connections, 128),
    TransOpts = #{socket_opts => [{port, Port}], max_connections => MaxConnections,
                  num_acceptors => 2},
    ProtoOpts = #{env => #{dispatch => Dispatch}, idle_timeout => 60000,
                  request_timeout => 5000, max_headers => 50,
                  max_header_name_length => 64, max_header_value_length => 4096,
                  max_request_line_length => 1024},
    cowboy:start_clear(beamvoice_listener, TransOpts, ProtoOpts).

port() ->
    case os:getenv("PORT") of
        false -> application:get_env(beamvoice, port, 8080);
        Value ->
            case string:to_integer(Value) of
                {Port, []} when Port > 0, Port =< 65535 -> Port;
                _ -> error({invalid_port, Value})
            end
    end.
