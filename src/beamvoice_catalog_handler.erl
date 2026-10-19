-module(beamvoice_catalog_handler).
-export([init/2]).

init(Req, _) ->
    Header = cowboy_req:header(<<"authorization">>, Req, <<>>),
    Auth = case Header of
        <<"Bearer ", Token/binary>> -> beamvoice_auth:authenticate(Token);
        _ -> {error, unauthorized}
    end,
    case Auth of
        {ok, Claims} -> dispatch(cowboy_req:method(Req), Claims, Req);
        _ -> respond(401, #{error => unauthorized}, Req)
    end.

dispatch(<<"GET">>, Claims, Req) ->
    case cowboy_req:bindings(Req) of
        Bindings when map_size(Bindings) =:= 0 ->
            respond(200, #{servers => beamvoice_catalog:list(Claims)}, Req);
        _ -> respond(405, #{error => method_not_allowed}, Req)
    end;
dispatch(Method, Claims, Req) ->
    case maps:get(admin, Claims, false) of
        true -> mutate(Method, cowboy_req:bindings(Req), Req);
        false -> respond(403, #{error => forbidden}, Req)
    end.

mutate(<<"POST">>, Bindings, Req) when map_size(Bindings) =:= 0 ->
    with_body(Req, fun(#{<<"id">> := Id, <<"name">> := Name} = Body, R)
                       when map_size(Body) =:= 2 ->
                           result(beamvoice_catalog:create_server(Id, Name), R);
                      (_, R) -> respond(400, #{error => bad_request}, R) end);
mutate(<<"DELETE">>, #{server := Server, channel := Channel}, Req) ->
    result(beamvoice_catalog:delete_channel(Server, Channel), Req);
mutate(<<"PUT">>, #{server := Server, channel := Channel}, Req) ->
    with_name(Req, fun(Name, R) ->
                           result(beamvoice_catalog:rename_channel(Server, Channel, Name), R)
                   end);
mutate(<<"POST">>, #{server := Server} = Bindings, Req) when map_size(Bindings) =:= 1 ->
    with_body(Req, fun(#{<<"id">> := Id, <<"name">> := Name} = Body, R)
                       when map_size(Body) =:= 2 ->
                           result(beamvoice_catalog:create_channel(Server, Id, Name), R);
                      (_, R) -> respond(400, #{error => bad_request}, R) end);
mutate(<<"DELETE">>, #{server := Server}, Req) ->
    result(beamvoice_catalog:delete_server(Server), Req);
mutate(<<"PUT">>, #{server := Server}, Req) ->
    with_name(Req, fun(Name, R) -> result(beamvoice_catalog:rename_server(Server, Name), R) end);
mutate(_, _, Req) -> respond(405, #{error => method_not_allowed}, Req).

with_name(Req, Fun) ->
    with_body(Req, fun(#{<<"name">> := Name} = Body, R) when map_size(Body) =:= 1 ->
                           Fun(Name, R);
                      (_, R) -> respond(400, #{error => bad_request}, R) end).

with_body(Req, Fun) ->
    case cowboy_req:read_body(Req, #{length => 4096, period => 5000}) of
        {ok, Data, Next} ->
            try Fun(jsx:decode(Data, [return_maps]), Next)
            catch _:_ -> respond(400, #{error => bad_request}, Next) end;
        {more, _, Next} -> respond(413, #{error => body_too_large}, Next)
    end.

result(ok, Req) -> respond(200, #{ok => true}, Req);
result({error, not_found}, Req) -> respond(404, #{error => not_found}, Req);
result({error, invalid_or_exists}, Req) -> respond(409, #{error => invalid_or_exists}, Req);
result({error, invalid_name}, Req) -> respond(400, #{error => invalid_name}, Req);
result({error, in_use}, Req) -> respond(409, #{error => in_use}, Req);
result({error, not_empty}, Req) -> respond(409, #{error => not_empty}, Req);
result({error, _}, Req) -> respond(500, #{error => persistence_failed}, Req).

respond(Status, Body, Req) ->
    Next = cowboy_req:reply(Status, #{<<"content-type">> => <<"application/json">>,
                                      <<"cache-control">> => <<"no-store">>},
                            jsx:encode(Body), Req),
    {ok, Next, undefined}.
