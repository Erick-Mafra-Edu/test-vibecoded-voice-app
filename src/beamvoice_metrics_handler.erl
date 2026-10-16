-module(beamvoice_metrics_handler).
-export([init/2]).
init(Req, State) ->
    case cowboy_req:header(<<"authorization">>, Req, <<>>) of
        <<"Bearer ", Token/binary>> ->
            case beamvoice_auth:authenticate(Token) of
                {ok, _} -> {ok, cowboy_req:reply(200, #{<<"content-type">> => <<"text/plain; version=0.0.4">>},
                                                beamvoice_metrics:render(), Req), State};
                _ -> denied(Req, State)
            end;
        _ -> denied(Req, State)
    end.
denied(Req, State) -> {ok, cowboy_req:reply(401, #{}, <<>>, Req), State}.
