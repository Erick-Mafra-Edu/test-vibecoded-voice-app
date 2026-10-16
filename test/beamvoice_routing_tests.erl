-module(beamvoice_routing_tests).
-include_lib("eunit/include/eunit.hrl").

metrics(Seq) -> #{sequence => Seq, window_ms => 1000, rtt_ms => 20,
                  jitter_ms => 2, loss => 0, packets => 50,
                  ice => connected, dtls => connected}.
options() -> #{sustain_ms => 30, cooldown_ms => 60, tick_ms => 5,
               switch_timeout_ms => 80, fresh_ms => 500}.
event(Event, Pid, Route) ->
    receive {Event, Pid, Epoch, Route} -> Epoch after 500 -> error({missing_event, Event}) end.
activate(Pid, Route) ->
    Epoch = event(route_prepare, Pid, Route),
    ?assertEqual(ok, beamvoice_route_coordinator:ready(Pid, Epoch, Route)),
    ?assertEqual(Epoch, event(route_commit, Pid, Route)),
    ?assertEqual(ok, beamvoice_route_coordinator:acknowledge(Pid, Epoch)),
    ?assertEqual(Epoch, event(route_active, Pid, Route)),
    Epoch.

make_before_break_and_rollback_test() ->
    {ok, Pid} = beamvoice_route_coordinator:start_link(self(), options()),
    try
        ok = beamvoice_route_coordinator:report(Pid, p2p, metrics(0)),
        Epoch = activate(Pid, p2p),
        ?assertEqual({error, stale_metrics}, beamvoice_route_coordinator:report(Pid, p2p, metrics(0))),
        ok = beamvoice_route_coordinator:report(Pid, sfu, metrics(0)),
        ok = beamvoice_route_coordinator:report(Pid, p2p, (metrics(1))#{loss := 0.5}),
        Next = event(route_prepare, Pid, sfu),
        ?assert(Next > Epoch),
        ?assertMatch(#{active := p2p, target := sfu}, beamvoice_route_coordinator:status(Pid)),
        ?assertEqual({error, invalid_transition}, beamvoice_route_coordinator:ready(Pid, Epoch, sfu)),
        ?assertEqual({error, invalid_transition}, beamvoice_route_coordinator:acknowledge(Pid, Next)),
        ?assertEqual(Next, event(route_rollback, Pid, p2p)),
        ?assertMatch(#{active := p2p, target := none}, beamvoice_route_coordinator:status(Pid))
    after beamvoice_route_coordinator:close(Pid) end.

fallback_recovery_test() ->
    {ok, Pid} = beamvoice_route_coordinator:start_link(self(), options()),
    try
        ok = beamvoice_route_coordinator:report(Pid, sfu, metrics(0)),
        activate(Pid, sfu),
        ok = beamvoice_route_coordinator:report(Pid, p2p, metrics(0)),
        ?assertMatch(#{active := sfu, target := none}, beamvoice_route_coordinator:status(Pid)),
        activate(Pid, p2p),
        ?assertMatch(#{active := p2p}, beamvoice_route_coordinator:status(Pid))
    after beamvoice_route_coordinator:close(Pid) end.

invalid_and_no_media_test() ->
    {ok, Pid} = beamvoice_route_coordinator:start_link(self(), options()),
    try
        ?assertEqual({error, invalid_metrics}, beamvoice_route_coordinator:report(Pid, p2p, #{})),
        ?assertEqual({error, invalid_metrics}, beamvoice_route_coordinator:report(Pid, p2p, (metrics(0))#{loss := 2})),
        ok = beamvoice_route_coordinator:report(Pid, p2p, (metrics(0))#{packets := 0}),
        ?assertMatch(#{active := none, target := none}, beamvoice_route_coordinator:status(Pid))
    after beamvoice_route_coordinator:close(Pid) end.

owner_cleanup_test() ->
    Owner = spawn(fun() -> receive stop -> ok end end),
    {ok, Pid} = beamvoice_route_coordinator:start_link(Owner, options()),
    Ref = monitor(process, Pid),
    Owner ! stop,
    receive {'DOWN', Ref, process, Pid, normal} -> ok after 500 -> error(orphan) end.
