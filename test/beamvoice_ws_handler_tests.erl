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
    Data = binary:copy(<<"a">>, 4097),
    ?assertMatch({reply, {close, 1009, _}, _},
                 beamvoice_ws_handler:websocket_handle({text, Data}, state())).

rate_limit_test() ->
    State = lists:foldl(
        fun(_, Current) ->
            {reply, {text, _}, Next} = beamvoice_ws_handler:websocket_handle({text, <<"{}">>}, Current),
            Next
        end, state(), lists:seq(1, 20)),
    ?assertMatch({reply, {close, 1008, _}, _},
                 beamvoice_ws_handler:websocket_handle({text, <<"{}">>}, State)).

state() ->
    #{room => undefined, user => undefined,
      rate_started => erlang:monotonic_time(millisecond), rate_count => 0}.
