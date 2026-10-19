-module(beamvoice_ws_handler).
-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2, terminate/3]).
-define(MAX_MESSAGES, 32).
-define(MEDIA, 'Elixir.BeamVoice.Media.Session').
-define(RATE_WINDOW_MS, 1000).
init(Req, _Opts) ->
    case allowed_origin(cowboy_req:header(<<"origin">>, Req)) of
        true ->
            State = #{room => undefined, user => undefined,
                      claims => undefined, media => undefined, routes => #{},
                      offers_started => erlang:monotonic_time(millisecond), offers => 0,
                      rate_started => erlang:monotonic_time(millisecond), rate_count => 0},
            {cowboy_websocket, Req, State,
             #{idle_timeout => 60000, max_frame_size => 20000, active_n => 20}};
        false ->
            Reply = cowboy_req:reply(403, #{<<"content-type">> => <<"application/json">>},
                                     <<"{\"error\":\"origin_not_allowed\"}">>, Req),
            {ok, Reply, undefined}
    end.
websocket_init(State) ->
    erlang:send_after(5000, self(), auth_timeout),
    {ok, State}.
websocket_handle(Frame, State0) ->
    case check_rate(State0) of
        {ok, State} -> handle_frame(Frame, State);
        {error, State} -> {reply, {close, 1008, <<"rate_limit">>}, State}
    end.

handle_frame({text, Data}, State) when byte_size(Data) =< 20000 ->
    Decoded = try {ok, jsx:decode(Data, [return_maps])} catch _:_ -> invalid end,
    case Decoded of
        invalid -> error_reply(bad_json, State);
        {ok, Message} ->
            try handle_message(Message, State)
            catch exit:_ -> error_reply(backend_unavailable, State)
            end
    end;
handle_frame({text, _Data}, State) ->
    {reply, {close, 1009, <<"message_too_large">>}, State};
handle_frame(_, State) -> error_reply(bad_request, State).

handle_message(#{<<"type">> := <<"auth">>, <<"token">> := Token} = M, State)
  when map_size(M) =:= 2 ->
    case maps:get(claims, State, undefined) of
        undefined ->
            case beamvoice_auth:authenticate(Token) of
                {ok, Claims} -> reply(#{type => authenticated, user => maps:get(user, Claims)},
                                      State#{claims => Claims, user => maps:get(user, Claims)});
                _ -> error_reply(unauthorized, State)
            end;
        _ -> error_reply(already_authenticated, State)
    end;
handle_message(Message, State) ->
    case maps:get(claims, State, undefined) of
        undefined -> error_reply(unauthorized, State);
        _ -> authenticated(Message, State)
    end.

authenticated(#{<<"type">> := <<"join">>, <<"room">> := Room} = Message, State)
  when map_size(Message) =:= 2, is_binary(Room), byte_size(Room) > 0, byte_size(Room) =< 64 ->
    case beamvoice_auth:allowed(maps:get(claims, State), Room) of
        false -> error_reply(forbidden, State);
        true ->
            User = maps:get(user, State),
            case maps:get(room, State) of
                undefined ->
                    case beamvoice_room_registry:get_or_create(Room) of
                        {ok, Pid} ->
                            case beamvoice_room:join(Pid, User, self()) of
                                ok ->
                                    Ref = monitor(process, Pid),
                                    {ok, Key} = beamvoice_room:key(Pid, User, self()),
                                    reply(#{type => joined, user => User,
                                            members => beamvoice_room:members(Pid),
                                            media_key => Key},
                                          State#{room => Pid, room_ref => Ref});
                                {error, Reason} -> error_reply(Reason, State)
                            end;
                        {error, Reason} -> error_reply(Reason, State)
                    end;
                _ -> error_reply(already_in_room, State)
            end
    end;
authenticated(#{<<"type">> := <<"members">>} = Message, State) when map_size(Message) =:= 1 ->
            case maps:get(room, State) of
                undefined -> error_reply(not_in_room, State);
                Pid ->
                    Payload = jsx:encode(#{type => <<"members">>,
                                           members => beamvoice_room:members(Pid)}),
                    {reply, {text, Payload}, State}
            end;
authenticated(M, #{room := Room} = State) when is_pid(Room), is_map(M) ->
    room_message(M, State);
authenticated(_, State) -> error_reply(bad_request, State).

room_message(#{<<"type">> := <<"signal">>, <<"to">> := To} = M, State)
  when map_size(M) =:= 3, is_binary(To) ->
    Payload = maps:without([<<"type">>, <<"to">>], M),
    case valid_signal(Payload) of
        true ->
            case beamvoice_room:session(maps:get(room, State), To) of
                {ok, Target} ->
                    case process_info(Target, message_queue_len) of
                        {message_queue_len, N} when N < 256 ->
                            Target ! {signaling, Payload#{type => signal, from => maps:get(user, State)}},
                            {ok, State};
                        _ -> error_reply(slow_peer, State)
                    end;
                _ -> error_reply(not_found, State)
            end;
        false -> error_reply(invalid_signal, State)
    end;
room_message(#{<<"type">> := <<"chat">>, <<"content">> := Content} = M, State)
  when map_size(M) =:= 2, is_binary(Content), byte_size(Content) > 0,
       byte_size(Content) =< 2000 ->
    result(beamvoice_room:chat(maps:get(room, State), maps:get(user, State), self(), Content), State);
room_message(#{<<"type">> := <<"media_offer">>, <<"transport">> := Id,
               <<"publisher">> := Publisher, <<"sdp">> := SDP} = M, State)
  when map_size(M) =:= 4, is_binary(Id), byte_size(Id) > 0, byte_size(Id) =< 64,
       is_binary(Publisher) ->
    case valid_description(SDP) andalso maps:get(<<"type">>, SDP) =:= <<"offer">> of
        false -> error_reply(invalid_sdp, State);
        true -> media_offer(Id, Publisher, SDP, State)
    end;
room_message(#{<<"type">> := <<"media_candidate">>, <<"transport">> := Id,
               <<"candidate">> := Candidate} = M, #{media := Media} = State)
  when map_size(M) =:= 3, is_pid(Media), is_binary(Id) ->
    case valid_candidate(Candidate) of
        true -> result(?MEDIA:candidate(Media, Id, Candidate), State);
        false -> error_reply(invalid_candidate, State)
    end;
room_message(#{<<"type">> := <<"route_metrics">>, <<"publisher">> := Publisher,
               <<"route">> := Route, <<"metrics">> := M} = Message, State)
  when map_size(Message) =:= 4, is_binary(Publisher), is_map(M) ->
    case {route(Route), metrics(M), authorized_publisher(Publisher, State)} of
        {invalid, _, _} -> error_reply(invalid_metrics, State);
        {_, invalid, _} -> error_reply(invalid_metrics, State);
        {_, _, false} -> error_reply(forbidden, State);
        {R, Values, true} ->
            {Pid, Next} = coordinator(Publisher, State),
            result(beamvoice_route_coordinator:report(Pid, R, Values), Next)
    end;
room_message(#{<<"type">> := <<"route_ready">>, <<"publisher">> := Publisher,
               <<"epoch">> := Epoch, <<"route">> := Route} = M, State)
  when map_size(M) =:= 4, is_integer(Epoch), Epoch >= 0 ->
    route_call(Publisher, fun(Pid) -> beamvoice_route_coordinator:ready(Pid, Epoch, route(Route)) end, State);
room_message(#{<<"type">> := <<"route_ack">>, <<"publisher">> := Publisher,
               <<"epoch">> := Epoch} = M, State)
  when map_size(M) =:= 3, is_integer(Epoch), Epoch >= 0 ->
    route_call(Publisher, fun(Pid) -> beamvoice_route_coordinator:acknowledge(Pid, Epoch) end, State);
room_message(#{<<"type">> := <<"lab_kill_media">>} = M, #{media := Media} = State)
  when map_size(M) =:= 1, is_pid(Media) ->
    case os:getenv("BEAMVOICE_LAB_FAULTS") of
        "true" -> exit(Media, kill), {ok, State};
        _ -> error_reply(forbidden, State)
    end;
room_message(_, State) -> error_reply(bad_request, State).

websocket_info(auth_timeout, State) ->
    case maps:get(claims, State, undefined) of
        undefined -> {reply, {close, 1008, <<"auth_timeout">>}, State};
        _ -> {ok, State}
    end;
websocket_info({signaling, #{type := peer_left, user := User} = M}, State) ->
    Routes = maps:get(routes, State, #{}),
    case maps:find(User, Routes) of {ok, P} -> catch beamvoice_route_coordinator:close(P); _ -> ok end,
    reply(M, State#{routes => maps:remove(User, Routes)});
websocket_info({signaling, M}, State) -> reply(M, State);
websocket_info({media_signal, M}, State) -> reply(M, State);
websocket_info({'DOWN', Ref, process, _, _}, #{room_ref := Ref} = State) ->
    {reply, {close, 1011, <<"room_closed">>}, State};
websocket_info({'DOWN', Ref, process, _, _}, #{media_ref := Ref} = State) ->
    reply(#{type => media_failed}, State#{media => undefined});
websocket_info({Event, Pid, Epoch, Route}, State)
  when Event =:= route_prepare; Event =:= route_commit; Event =:= route_active; Event =:= route_rollback ->
    case [User || {User, P} <- maps:to_list(maps:get(routes, State, #{})), P =:= Pid] of
        [Publisher] ->
            forwarding(Event, Route, Publisher, State),
            case Event of
                route_active -> beamvoice_metrics:inc(route_switch_total);
                route_rollback -> beamvoice_metrics:inc(route_switch_failure_total);
                _ -> ok
            end,
            reply(#{type => Event, publisher => Publisher, epoch => Epoch, route => Route}, State);
        _ -> {ok, State}
    end;
websocket_info(_, State) -> {ok, State}.
terminate(_Reason, _Req, #{room := Pid, user := User}) when is_pid(Pid) ->
    catch beamvoice_room:leave(Pid, User), ok;
terminate(_, _, _) -> ok.
error_reply(Reason, State) ->
    {reply, {text, jsx:encode(#{type => <<"error">>, reason => Reason})}, State}.

reply(M, State) -> {reply, {text, jsx:encode(M)}, State}.
result(ok, State) -> {ok, State};
result({ok, M}, State) when is_map(M) -> reply(M, State);
result({error, Reason}, State) when is_atom(Reason) -> error_reply(Reason, State);
result(_, State) -> error_reply(media_failed, State).

valid_description(#{<<"type">> := Type, <<"sdp">> := SDP} = M) ->
    map_size(M) =:= 2 andalso (Type =:= <<"offer">> orelse Type =:= <<"answer">>)
        andalso is_binary(SDP) andalso byte_size(SDP) > 0 andalso byte_size(SDP) =< 16384;
valid_description(_) -> false.
valid_candidate(#{<<"candidate">> := C} = M) when is_binary(C), byte_size(C) =< 2048 ->
    lists:all(fun(K) -> lists:member(K, [<<"candidate">>, <<"sdpMid">>, <<"sdpMLineIndex">>, <<"usernameFragment">>]) end, maps:keys(M))
    andalso nullable_binary(maps:get(<<"sdpMid">>, M, null), 64)
    andalso nullable_binary(maps:get(<<"usernameFragment">>, M, null), 256)
    andalso case maps:get(<<"sdpMLineIndex">>, M, null) of null -> true; I when is_integer(I), I >= 0, I < 32 -> true; _ -> false end;
valid_candidate(_) -> false.
nullable_binary(null, _) -> true;
nullable_binary(B, Max) -> is_binary(B) andalso byte_size(B) =< Max.
valid_signal(#{<<"description">> := D}) -> valid_description(D);
valid_signal(#{<<"candidate">> := C}) -> valid_candidate(C);
valid_signal(_) -> false.

media_offer(Id, Publisher, SDP, State) ->
    Now = erlang:monotonic_time(millisecond),
    S = case Now - maps:get(offers_started, State, Now) >= 30000 of
        true -> State#{offers_started => Now, offers => 0}; false -> State
    end,
    case {authorized_publisher(Publisher, S) orelse Publisher =:= maps:get(user, S), maps:get(offers, S, 0) < 30} of
        {false, _} -> error_reply(forbidden, S);
        {_, false} -> error_reply(offer_limit, S);
        {true, true} ->
            case ensure_media(S) of
                {ok, Media, Next} -> result(?MEDIA:offer(Media, Id, Publisher, SDP), Next#{offers => maps:get(offers, S, 0) + 1});
                {error, Next} -> error_reply(media_unavailable, Next)
            end
    end.
ensure_media(#{media := Pid} = State) when is_pid(Pid) -> {ok, Pid, State};
ensure_media(State) ->
    case ?MEDIA:start(self(), maps:get(room, State), maps:get(user, State)) of
        {ok, Pid} -> {ok, Pid, State#{media => Pid, media_ref => monitor(process, Pid)}};
        _ -> {error, State}
    end.
authorized_publisher(Publisher, State) ->
    Publisher =/= maps:get(user, State) andalso
    case beamvoice_room:session(maps:get(room, State), Publisher) of {ok, _} -> true; _ -> false end.
coordinator(Publisher, State) ->
    Routes = maps:get(routes, State, #{}),
    case maps:find(Publisher, Routes) of
        {ok, Pid} -> {Pid, State};
        error ->
            {ok, Pid} = beamvoice_route_coordinator:start_link(self(), application:get_env(beamvoice, route_options, #{})),
            {Pid, State#{routes => Routes#{Publisher => Pid}}}
    end.
route_call(Publisher, F, State) ->
    case maps:find(Publisher, maps:get(routes, State, #{})) of
        {ok, Pid} -> result(F(Pid), State);
        error -> error_reply(not_found, State)
    end.
route(<<"p2p">>) -> p2p;
route(<<"sfu">>) -> sfu;
route(_) -> invalid.
metrics(M) ->
    try
        Values = maps:from_list([{K, maps:get(atom_to_binary(K), M)} || K <-
            [sequence, window_ms, rtt_ms, jitter_ms, loss, packets]]),
        V = Values#{ice => connectivity(maps:get(<<"ice">>, M)), dtls => connectivity(maps:get(<<"dtls">>, M))},
        case beamvoice_network_metrics:validate(V) of {ok, Valid} -> Valid; _ -> invalid end
    catch error:_ -> invalid end.
connectivity(<<"connected">>) -> connected;
connectivity(<<"failed">>) -> failed;
connectivity(<<"disconnected">>) -> disconnected;
connectivity(<<"connecting">>) -> connecting;
connectivity(_) -> invalid.
forwarding(Event, Route, Publisher, #{media := Media}) when is_pid(Media) ->
    case {Event, Route} of
        {route_prepare, sfu} -> catch ?MEDIA:set_forwarding(Media, Publisher, true);
        {route_active, p2p} -> catch ?MEDIA:set_forwarding(Media, Publisher, false);
        {route_rollback, Old} when Old =/= sfu -> catch ?MEDIA:set_forwarding(Media, Publisher, false);
        _ -> ok
    end;
forwarding(_, _, _, _) -> ok.

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
