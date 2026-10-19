-module(beamvoice_ws_handler_tests).
-include_lib("eunit/include/eunit.hrl").

unexpected_fields_test() ->
    {reply, {text, Payload}, _} = beamvoice_ws_handler:websocket_handle(
        {text, <<"{\"type\":\"members\",\"admin\":true}">>}, state()),
    ?assertMatch(#{<<"reason">> := <<"bad_request">>}, jsx:decode(Payload, [return_maps])).

malformed_json_test() ->
    {reply, {text, Payload}, _} = beamvoice_ws_handler:websocket_handle({text, <<"{">>}, state()),
    ?assertMatch(#{<<"reason">> := <<"bad_json">>}, jsx:decode(Payload, [return_maps])).

oversized_message_test() ->
    Data = binary:copy(<<"a">>, 20001),
    ?assertMatch({reply, {close, 1009, _}, _},
                 beamvoice_ws_handler:websocket_handle({text, Data}, state())).

rate_limit_test() ->
    State = lists:foldl(
        fun(_, Current) ->
            {reply, {text, _}, Next} = beamvoice_ws_handler:websocket_handle({text, <<"{}">>}, Current),
            Next
        end, state(), lists:seq(1, 32)),
    ?assertMatch({reply, {close, 1008, _}, _},
                 beamvoice_ws_handler:websocket_handle({text, <<"{}">>}, State)).

lab_fault_disabled_test() ->
    Media = spawn(fun() -> receive stop -> ok end end),
    try
        S = (state())#{room => self(), media => Media},
        {reply, {text, Payload}, _} = beamvoice_ws_handler:websocket_handle(
            {text, <<"{\"type\":\"lab_kill_media\"}">>}, S),
        ?assertMatch(#{<<"reason">> := <<"forbidden">>}, jsx:decode(Payload, [return_maps])),
        ?assert(is_process_alive(Media))
    after Media ! stop end.

chat_requires_room_test() ->
    {reply, {text, Payload}, _} = beamvoice_ws_handler:websocket_handle(
        {text, <<"{\"type\":\"chat\",\"content\":\"hello\"}">>}, state()),
    ?assertMatch(#{<<"reason">> := <<"bad_request">>}, jsx:decode(Payload, [return_maps])).

state() ->
    #{room => undefined, user => <<"test">>, claims => #{user => <<"test">>, rooms => [<<"test">>]},
      rate_started => erlang:monotonic_time(millisecond), rate_count => 0}.
