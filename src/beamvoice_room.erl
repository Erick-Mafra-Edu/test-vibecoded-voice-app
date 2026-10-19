-module(beamvoice_room).
-behaviour(gen_server).
-export([start_link/1, join/3, leave/2, members/1, session/2, chat/4, key/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-define(CALL_TIMEOUT, 2000).
start_link(Id) -> gen_server:start_link(?MODULE, Id, []).
join(Pid, UserId, SessionPid)
  when is_binary(UserId), byte_size(UserId) > 0, byte_size(UserId) =< 64,
       is_pid(SessionPid) ->
    gen_server:call(Pid, {join, UserId, SessionPid}, ?CALL_TIMEOUT);
join(_, _, _) -> {error, invalid_member}.
leave(Pid, UserId) -> gen_server:call(Pid, {leave, UserId}, ?CALL_TIMEOUT).
members(Pid) -> gen_server:call(Pid, members, ?CALL_TIMEOUT).
key(Pid, User, SessionPid) -> gen_server:call(Pid, {key, User, SessionPid}, ?CALL_TIMEOUT).
session(Pid, User) -> gen_server:call(Pid, {session, User}, ?CALL_TIMEOUT).
chat(Pid, User, SessionPid, Content) ->
    gen_server:call(Pid, {chat, User, SessionPid, Content}, ?CALL_TIMEOUT).
init(Id) ->
    schedule_empty_stop(),
    {ok, #{id => Id, members => #{}, key => base64:encode(crypto:strong_rand_bytes(32))}}.
handle_call({join, UserId, SessionPid}, _From, #{members := Members} = State) ->
    MaxMembers = application:get_env(beamvoice, max_room_members, 24),
    case maps:find(UserId, Members) of
        {ok, {ExistingPid, OldRef}} ->
            case erlang:is_process_alive(ExistingPid) of
                true -> {reply, {error, already_joined}, State};
                false ->
                    erlang:demonitor(OldRef, [flush]),
                    Ref = erlang:monitor(process, SessionPid),
                    {reply, ok, State#{members := Members#{UserId => {SessionPid, Ref}}}}
            end;
        error when map_size(Members) >= MaxMembers ->
            {reply, {error, room_full}, State};
        error ->
            Ref = erlang:monitor(process, SessionPid),
            notify(Members, #{type => peer_joined, user => UserId}),
            {reply, ok, State#{members := Members#{UserId => {SessionPid, Ref}}}}
    end;
handle_call({leave, UserId}, _From, #{members := Members} = State) ->
    case maps:take(UserId, Members) of
        {{_Pid, Ref}, Remaining} ->
            erlang:demonitor(Ref, [flush]),
            notify(Remaining, #{type => peer_left, user => UserId}),
            case map_size(Remaining) of
                0 -> schedule_empty_stop(), {reply, ok, State#{members := Remaining}};
                _ -> {reply, ok, State#{members := Remaining}}
            end;
        error -> {reply, {error, not_found}, State}
    end;
handle_call(members, _From, #{members := Members} = State) ->
    {reply, maps:keys(Members), State};
handle_call({key, User, SessionPid}, _From, #{members := Members, key := Key} = State) ->
    Reply = case maps:find(User, Members) of
        {ok, {SessionPid, _}} -> {ok, Key};
        _ -> {error, not_in_room}
    end,
    {reply, Reply, State};
handle_call({session, User}, _From, #{members := Members} = State) ->
    Reply = case maps:find(User, Members) of
        {ok, {Pid, _}} -> {ok, Pid};
        error -> {error, not_found}
    end,
    {reply, Reply, State};
handle_call({chat, User, SessionPid, Content}, _From, #{members := Members} = State) ->
    case maps:find(User, Members) of
        {ok, {SessionPid, _}} ->
            maps:foreach(fun(_, {Pid, _}) ->
                case process_info(Pid, message_queue_len) of
                    {message_queue_len, N} when N < 256 ->
                        Pid ! {signaling, #{type => chat, from => User, content => Content}};
                    _ -> ok
                end
            end, Members),
            {reply, ok, State};
        _ -> {reply, {error, not_in_room}, State}
    end;
handle_call(_, _From, State) -> {reply, {error, bad_request}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #{members := Members} = State) ->
    Remaining = maps:filter(fun(_Id, {_Session, R}) -> R =/= Ref end, Members),
    [notify(Remaining, #{type => peer_left, user => Id}) ||
        {Id, {_, R}} <- maps:to_list(Members), R =:= Ref],
    case map_size(Remaining) of
        0 -> schedule_empty_stop(), {noreply, State#{members := Remaining}};
        _ -> {noreply, State#{members := Remaining}}
    end;
handle_info(stop_if_empty, #{members := Members} = State) when map_size(Members) =:= 0 ->
    {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

schedule_empty_stop() ->
    erlang:send_after(application:get_env(beamvoice, room_empty_ttl_ms, 1000),
                      self(), stop_if_empty).

notify(Members, Message) ->
    maps:foreach(fun(_, {Pid, _}) -> Pid ! {signaling, Message} end, Members).
