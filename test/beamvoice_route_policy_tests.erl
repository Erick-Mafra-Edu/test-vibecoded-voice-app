-module(beamvoice_route_policy_tests).
-include_lib("eunit/include/eunit.hrl").
p2p_wins_test() -> ?assertEqual(p2p, beamvoice_route_policy:choose(#{p2p_ms => 12, sfu_ms => 70}, 10)).
sfu_wins_test() -> ?assertEqual(sfu, beamvoice_route_policy:choose(#{p2p_ms => 65, sfu_ms => 30}, 10)).
hysteresis_test() -> ?assertEqual(sfu, beamvoice_route_policy:choose(#{p2p_ms => 25, sfu_ms => 30}, 10)).
invalid_metrics_test() -> ?assertMatch({error, _}, beamvoice_route_policy:choose(#{}, 10)).
