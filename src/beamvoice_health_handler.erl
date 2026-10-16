-module(beamvoice_health_handler).
-export([init/2]).
init(Req, State) ->
    {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"application/json">>},
                          <<"{\"status\":\"ok\"}">>, Req), State}.
