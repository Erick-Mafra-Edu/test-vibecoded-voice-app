-module(beamvoice_network_metrics).
-export([validate/1, healthy/2]).

validate(#{sequence := Seq, window_ms := Window, rtt_ms := RTT,
           jitter_ms := Jitter, loss := Loss, packets := Packets,
           ice := ICE, dtls := DTLS} = M)
  when is_integer(Seq), Seq >= 0, is_integer(Window), Window >= 100, Window =< 60000,
       (RTT =:= null orelse (is_number(RTT) andalso RTT >= 0 andalso RTT =< 60000)),
       is_number(Jitter), Jitter >= 0, Jitter =< 60000,
       is_number(Loss), Loss >= 0, Loss =< 1,
       is_integer(Packets), Packets >= 0, Packets =< 10000000,
       (ICE =:= connected orelse ICE =:= failed orelse ICE =:= disconnected),
       (DTLS =:= connected orelse DTLS =:= failed orelse DTLS =:= connecting) ->
    {ok, maps:with([sequence, window_ms, rtt_ms, jitter_ms, loss, packets, ice, dtls], M)};
validate(_) -> {error, invalid_metrics}.

healthy(#{ice := connected, dtls := connected, packets := N,
          rtt_ms := RTT, jitter_ms := Jitter, loss := Loss}, Options) ->
    N >= maps:get(min_packets, Options) andalso
    (RTT =:= null orelse RTT =< maps:get(max_rtt_ms, Options)) andalso
    Jitter =< maps:get(max_jitter_ms, Options) andalso
    Loss =< maps:get(max_loss, Options);
healthy(_, _) -> false.
