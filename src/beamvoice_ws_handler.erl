-module(beamvoice_ws_handler).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
init(Req, _Opts) -> {cowboy_websocket, Req, #{room => undefined, user => undefined}}.
websocket_init(State) -> {ok, State}.
websocket_handle({text, Data}, State) when byte_size(Data) =< 4096 ->
    try jsx:decode(Data, [return_maps]) of
        #{<<"type">> := <<"join">>, <<"room">> := Room, <<"user">> := User}
          when is_binary(Room), is_binary(User), byte_size(User) > 0, byte_size(User) =< 64 ->
            case maps:get(room, State) of
                undefined ->
                    case beamvoice_room_registry:get_or_create(Room) of
                        {ok, Pid} ->
                            case beamvoice_room:join(Pid, User, self()) of
                                ok -> {reply, {text, <<"{\"type\":\"joined\"}">>},
                                       State#{room => Pid, user => User}};
                                {error, Reason} -> error_reply(Reason, State)
                            end;
                        {error, Reason} -> error_reply(Reason, State)
                    end;
                _ -> error_reply(already_in_room, State)
            end;
        #{<<"type">> := <<"members">>} ->
            case maps:get(room, State) of
                undefined -> error_reply(not_in_room, State);
                Pid ->
                    Payload = jsx:encode(#{type => <<"members">>,
                                           members => beamvoice_room:members(Pid)}),
                    {reply, {text, Payload}, State}
            end;
        _ -> error_reply(bad_request, State)
    catch _:_ -> error_reply(bad_json, State)
    end;
websocket_handle(_, State) -> error_reply(bad_request, State).
websocket_info(_, State) -> {ok, State}.
terminate(_Reason, _Req, #{room := Pid, user := User}) when is_pid(Pid) ->
    catch beamvoice_room:leave(Pid, User), ok;
terminate(_, _, _) -> ok.
error_reply(Reason, State) ->
    {reply, {text, jsx:encode(#{type => <<"error">>, reason => Reason})}, State}.
