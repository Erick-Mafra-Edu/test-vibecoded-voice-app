-module(beamvoice_room).
-behaviour(gen_server).
-export([start_link/1, join/3, leave/2, members/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start_link(Id) -> gen_server:start_link(?MODULE, Id, []).
join(Pid, UserId, SessionPid) -> gen_server:call(Pid, {join, UserId, SessionPid}).
leave(Pid, UserId) -> gen_server:call(Pid, {leave, UserId}).
members(Pid) -> gen_server:call(Pid, members).
init(Id) -> {ok, #{id => Id, members => #{}}}.
handle_call({join, UserId, SessionPid}, _From, #{members := Members} = State)
  when is_binary(UserId), is_pid(SessionPid) ->
    case maps:is_key(UserId, Members) of
        true -> {reply, {error, already_joined}, State};
        false ->
            Ref = erlang:monitor(process, SessionPid),
            {reply, ok, State#{members := Members#{UserId => {SessionPid, Ref}}}}
    end;
handle_call({leave, UserId}, _From, #{members := Members} = State) ->
    case maps:take(UserId, Members) of
        {{_Pid, Ref}, Remaining} ->
            erlang:demonitor(Ref, [flush]),
            {reply, ok, State#{members := Remaining}};
        error -> {reply, {error, not_found}, State}
    end;
handle_call(members, _From, #{members := Members} = State) ->
    {reply, maps:keys(Members), State};
handle_call(_, _From, State) -> {reply, {error, bad_request}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #{members := Members} = State) ->
    Remaining = maps:filter(fun(_Id, {_Session, R}) -> R =/= Ref end, Members),
    {noreply, State#{members := Remaining}};
handle_info(_, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.
