-module(beamvoice_catalog).
-behaviour(gen_server).
-export([start_link/0, list/1, create_server/2, rename_server/2, delete_server/1,
         create_channel/3, rename_channel/3, delete_channel/2, room_exists/1, valid_id/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
list(Claims) -> gen_server:call(?MODULE, {list, Claims}).
create_server(Id, Name) -> gen_server:call(?MODULE, {create_server, Id, Name}).
rename_server(Id, Name) -> gen_server:call(?MODULE, {rename_server, Id, Name}).
delete_server(Id) -> gen_server:call(?MODULE, {delete_server, Id}).
create_channel(Server, Id, Name) -> gen_server:call(?MODULE, {create_channel, Server, Id, Name}).
rename_channel(Server, Id, Name) -> gen_server:call(?MODULE, {rename_channel, Server, Id, Name}).
delete_channel(Server, Id) -> gen_server:call(?MODULE, {delete_channel, Server, Id}).
room_exists(Room) -> gen_server:call(?MODULE, {room_exists, Room}).

init([]) ->
    Path = case os:getenv("BEAMVOICE_CATALOG_FILE") of
        false -> application:get_env(beamvoice, catalog_file, "catalog.json");
        Value -> Value
    end,
    ok = filelib:ensure_dir(Path),
    Catalog = case file:read_file(Path) of
        {ok, Data} when byte_size(Data) =< 1048576 -> jsx:decode(Data, [return_maps]);
        {error, enoent} -> #{};
        {error, Reason} -> error({catalog_read_failed, Reason})
    end,
    true = is_map(Catalog),
    {ok, {Path, Catalog}}.

handle_call({list, Claims}, _From, State = {_Path, Catalog}) ->
    Visible = [server_view(Id, S) || {Id, S} <- maps:to_list(Catalog),
              beamvoice_auth:allowed(Claims, Id)],
    {reply, lists:sort(fun(A, B) -> maps:get(id, A) =< maps:get(id, B) end, Visible), State};
handle_call({room_exists, Room}, _From, State = {_Path, Catalog}) ->
    Reply = case binary:split(Room, <<"/">>) of
        [Server, Channel] ->
            case maps:find(Server, Catalog) of
                {ok, S} -> maps:is_key(Channel, maps:get(<<"channels">>, S));
                error -> false
            end;
        _ -> false
    end,
    {reply, Reply, State};
handle_call({create_server, Id, Name}, _From, State = {_Path, Catalog}) ->
    mutate(valid_id(Id) andalso valid_name(Name) andalso not maps:is_key(Id, Catalog),
           {error, invalid_or_exists}, Catalog#{Id => #{<<"name">> => Name, <<"channels">> => #{}}}, State);
handle_call({rename_server, Id, Name}, _From, State = {_Path, Catalog}) ->
    case maps:find(Id, Catalog) of
        {ok, Server} ->
            mutate(valid_name(Name), {error, invalid_name},
                   Catalog#{Id => Server#{<<"name">> => Name}}, State);
        error -> {reply, {error, not_found}, State}
    end;
handle_call({delete_server, Id}, _From, State = {_Path, Catalog}) ->
    case maps:find(Id, Catalog) of
        {ok, #{<<"channels">> := Channels}} when map_size(Channels) =:= 0 ->
            mutate(true, ok, maps:remove(Id, Catalog), State);
        {ok, _} -> {reply, {error, not_empty}, State};
        error -> {reply, {error, not_found}, State}
    end;
handle_call({create_channel, Server, Id, Name}, _From, State = {_Path, Catalog}) ->
    case maps:find(Server, Catalog) of
        {ok, S = #{<<"channels">> := Channels}} ->
            Valid = valid_id(Id) andalso valid_name(Name) andalso
                    byte_size(Server) + byte_size(Id) + 1 =< 64 andalso
                    not maps:is_key(Id, Channels),
            Updated = Catalog#{Server => S#{<<"channels">> => Channels#{Id => Name}}},
            mutate(Valid, {error, invalid_or_exists}, Updated, State);
        error -> {reply, {error, not_found}, State}
    end;
handle_call({rename_channel, Server, Id, Name}, _From, State = {_Path, Catalog}) ->
    case maps:find(Server, Catalog) of
        {ok, S = #{<<"channels">> := Channels}} ->
            case maps:is_key(Id, Channels) of
                true ->
                    mutate(valid_name(Name), {error, invalid_name},
                           Catalog#{Server => S#{<<"channels">> => Channels#{Id => Name}}}, State);
                false -> {reply, {error, not_found}, State}
            end;
        error -> {reply, {error, not_found}, State}
    end;
handle_call({delete_channel, Server, Id}, _From, State = {_Path, Catalog}) ->
    case maps:find(Server, Catalog) of
        {ok, S = #{<<"channels">> := Channels}} ->
            Room = case is_binary(Id) of
                true -> <<Server/binary, "/", Id/binary>>;
                false -> <<>>
            end,
            case {maps:is_key(Id, Channels), lists:member(Room, beamvoice_room_registry:list())} of
                {false, _} -> {reply, {error, not_found}, State};
                {true, true} -> {reply, {error, in_use}, State};
                {true, false} ->
                    Updated = Catalog#{Server => S#{<<"channels">> => maps:remove(Id, Channels)}},
                    mutate(true, ok, Updated, State)
            end;
        error -> {reply, {error, not_found}, State}
    end;
handle_call(_, _From, State) -> {reply, {error, bad_request}, State}.

mutate(false, Error, _Updated, State) -> {reply, Error, State};
mutate(true, _Error, Updated, {Path, _Old} = State) ->
    Temp = Path ++ ".tmp",
    case file:write_file(Temp, jsx:encode(Updated), [sync]) of
        ok ->
            case file:rename(Temp, Path) of
                ok -> {reply, ok, {Path, Updated}};
                {error, Reason} -> {reply, {error, Reason}, State}
            end;
        {error, Reason} -> {reply, {error, Reason}, State}
    end.

server_view(Id, #{<<"name">> := Name, <<"channels">> := Channels}) ->
    #{id => Id, name => Name,
      channels => [#{id => C, name => N, room => <<Id/binary, "/", C/binary>>}
                   || {C, N} <- lists:sort(maps:to_list(Channels))]}.

valid_id(B) when is_binary(B), byte_size(B) > 0, byte_size(B) =< 32 ->
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse
                        (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $- end,
              binary_to_list(B));
valid_id(_) -> false.
valid_name(B) -> is_binary(B) andalso byte_size(B) > 0 andalso byte_size(B) =< 80.

handle_cast(_, State) -> {noreply, State}.
handle_info(_, State) -> {noreply, State}.
terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.
