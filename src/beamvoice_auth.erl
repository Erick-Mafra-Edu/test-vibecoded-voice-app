-module(beamvoice_auth).
-export([load/0, authenticate/1, allowed/2]).

%% Opaque, individually provisioned bearer credentials. Never log credential values.
load() ->
    Entries = case os:getenv("BEAMVOICE_CREDENTIALS_FILE") of
        false -> application:get_env(beamvoice, credentials, []);
        Path ->
            {ok, Data} = file:read_file(Path),
            true = byte_size(Data) =< 1048576,
            jsx:decode(Data, [return_maps])
    end,
    true = is_list(Entries) andalso length(Entries) =< 1000,
    Credentials = [credential(E) || E <- Entries],
    Hashes = [Hash || {Hash, _} <- Credentials],
    true = length(Hashes) =:= length(lists:usort(Hashes)),
    persistent_term:put(?MODULE, Credentials),
    ok.

credential(#{<<"token">> := Token, <<"user">> := User, <<"rooms">> := Rooms} = Entry)
  when is_binary(Token), byte_size(Token) >= 32, byte_size(Token) =< 256,
       is_binary(User), byte_size(User) > 0, byte_size(User) =< 64,
       is_list(Rooms), length(Rooms) > 0, length(Rooms) =< 100 ->
    true = lists:all(fun(R) -> is_binary(R) andalso byte_size(R) > 0
                               andalso byte_size(R) =< 64 end, Rooms),
    Admin = maps:get(<<"admin">>, Entry, false),
    true = is_boolean(Admin),
    {crypto:hash(sha256, Token), #{user => User, rooms => Rooms, admin => Admin}}.

authenticate(Token) when is_binary(Token), byte_size(Token) >= 32, byte_size(Token) =< 256 ->
    Hash = crypto:hash(sha256, Token),
    case lists:keyfind(Hash, 1, persistent_term:get(?MODULE, [])) of
        {_, Claims} -> {ok, Claims};
        false -> {error, unauthorized}
    end;
authenticate(_) -> {error, unauthorized}.

allowed(#{rooms := Rooms} = Claims, Room) when is_binary(Room) ->
    case binary:split(Room, <<"/">>) of
        [Server, _Channel] ->
            (maps:get(admin, Claims, false) orelse lists:member(Server, Rooms))
                andalso beamvoice_catalog:room_exists(Room);
        [_] -> maps:get(admin, Claims, false) orelse lists:member(Room, Rooms);
        _ -> false
    end;
allowed(_, _) -> false.
