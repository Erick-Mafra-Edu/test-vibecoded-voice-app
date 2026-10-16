-module(beamvoice_route_policy).
-export([choose/2]).
%% Prefer direct only if it wins by 10 ms or more. Inputs are measured media-path estimates.
choose(#{p2p_ms := P2P, sfu_ms := SFU}, Margin)
  when is_number(P2P), is_number(SFU), P2P >= 0, SFU >= 0,
       is_number(Margin), Margin >= 0 ->
    case P2P + Margin =< SFU of true -> p2p; false -> sfu end;
choose(_, _) -> {error, invalid_metrics}.
