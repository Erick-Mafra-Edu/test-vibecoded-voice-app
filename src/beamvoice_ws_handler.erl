-module(beamvoice_ws_handler).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-define(MAX_MESSAGES, 20).
-define(RATE_WINDOW_MS, 1000).
init(Req, _Opts) ->
    case allowed_origin(cowboy_req:header(<<"origin">>, Req, undefined)) of
        true ->
            State = #{room => undefined, user => undefined,
                      rate_started => erlang:monotonic_time(millisecond), rate_count => 0},
            {cowboy_websocket, Req, State,
             #{idle_timeout => 60000, max_frame_size => 4096, active_n => 20}};
        false ->
            Reply = cowboy_req:reply(403, #{<<"content-type">> => <<"application/json">>},
                                     <<"{\"error\":\"origin_not_allowed\"}">>, Req),
            {ok, Reply, undefined}
    end.
websocket_init(State) -> {ok, State}.
websocket_handle(Frame, State0) ->
    case check_rate(State0) of
        {ok, State} -> handle_frame(Frame, State);
        {error, State} -> {reply, {close, 1008, <<"rate_limit">>}, State}
    end.

handle_frame({text, Data}, State) when byte_size(Data) =< 4096 ->
    try jsx:decode(Data, [return_maps]) of
        Message -> handle_message(Message, State)
    catch _:_ -> error_reply(bad_json, State)
    end;
handle_frame({text, _Data}, State) ->
    {reply, {close, 1009, <<"message_too_large">>}, State};
handle_frame(_, State) -> error_reply(bad_request, State).

handle_message(#{<<"type">> := <<"join">>, <<"room">> := Room, <<"user">> := User} = Message,
               State)
  when map_size(Message) =:= 3, is_binary(Room), is_binary(User),
       byte_size(User) > 0, byte_size(User) =< 64 ->
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
handle_message(#{<<"type">> := <<"members">>} = Message, State) when map_size(Message) =:= 1 ->
            case maps:get(room, State) of
                undefined -> error_reply(not_in_room, State);
                Pid ->
                    Payload = jsx:encode(#{type => <<"members">>,
                                           members => beamvoice_room:members(Pid)}),
                    {reply, {text, Payload}, State}
            end;
handle_message(_, State) -> error_reply(bad_request, State).
websocket_info(_, State) -> {ok, State}.
terminate(_Reason, _Req, #{room := Pid, user := User}) when is_pid(Pid) ->
    catch beamvoice_room:leave(Pid, User), ok;
terminate(_, _, _) -> ok.
error_reply(Reason, State) ->
    {reply, {text, jsx:encode(#{type => <<"error">>, reason => Reason})}, State}.

check_rate(#{rate_started := Started, rate_count := Count} = State) ->
    Now = erlang:monotonic_time(millisecond),
    case Now - Started >= ?RATE_WINDOW_MS of
        true -> {ok, State#{rate_started := Now, rate_count := 1}};
        false when Count < ?MAX_MESSAGES -> {ok, State#{rate_count := Count + 1}};
        false -> {error, State}
    end.

allowed_origin(undefined) -> true;
allowed_origin(Origin) ->
    Defaults = [<<"http://localhost:8080">>, <<"http://127.0.0.1:8080">>],
    Allowed = case os:getenv("ALLOWED_ORIGINS") of
        false -> Defaults;
        Value -> [unicode:characters_to_binary(string:trim(Item))
                  || Item <- string:split(Value, ",", all), string:trim(Item) =/= ""]
    end,
    lists:member(Origin, Allowed).
