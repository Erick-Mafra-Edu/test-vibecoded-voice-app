-module(beamvoice_route_coordinator).
-behaviour(gen_statem).
-export([start_link/2, report/3, ready/3, acknowledge/2, status/1, close/1]).
-export([init/1, callback_mode/0, handle_event/4]).

start_link(Owner, Options) -> gen_statem:start_link(?MODULE, {Owner, Options}, []).
report(Pid, Route, Metrics) -> gen_statem:call(Pid, {report, Route, Metrics}, 2000).
ready(Pid, Epoch, Route) -> gen_statem:call(Pid, {ready, Epoch, Route}, 2000).
acknowledge(Pid, Epoch) -> gen_statem:call(Pid, {acknowledge, Epoch}, 2000).
status(Pid) -> gen_statem:call(Pid, status, 2000).
close(Pid) -> gen_statem:stop(Pid).
callback_mode() -> handle_event_function.

init({Owner, Options}) when is_pid(Owner), is_map(Options) ->
    Defaults = #{fresh_ms => 3000, sustain_ms => 3000, cooldown_ms => 10000,
                 switch_timeout_ms => 3000, tick_ms => 250, min_packets => 5,
                 max_rtt_ms => 300, max_jitter_ms => 30, max_loss => 0.05},
    O = maps:merge(Defaults, Options),
    case valid_options(O) of
        false -> {stop, invalid_options};
        true ->
            Ref = erlang:monitor(process, Owner),
            {ok, probing, #{owner => Owner, monitor => Ref, options => O,
                           metrics => #{}, active => none, target => none, epoch => 0,
                           last_switch => now_ms() - maps:get(cooldown_ms, O),
                           candidate => none, candidate_since => now_ms()}, [tick(O)]}
    end.

handle_event({call, From}, status, State, D) ->
    {keep_state_and_data, [{reply, From, (maps:with([active, target, epoch], D))#{state => State}}]};
handle_event({call, From}, {report, Route, M}, State, D) when Route =:= p2p; Route =:= sfu ->
    case beamvoice_network_metrics:validate(M) of
        {ok, Valid} ->
            Metrics = maps:get(metrics, D),
            Previous = maps:get(Route, Metrics, #{sequence => -1}),
            case maps:get(sequence, Valid) > maps:get(sequence, Previous) of
                true ->
                    Updated = D#{metrics := Metrics#{Route => Valid#{received_at => now_ms()}}},
                    {Next, NextD, Actions} = evaluate(State, Updated),
                    {next_state, Next, NextD, [{reply, From, ok} | Actions]};
                false -> {keep_state_and_data, [{reply, From, {error, stale_metrics}}]}
            end;
        Error -> {keep_state_and_data, [{reply, From, Error}]}
    end;
handle_event({call, From}, {ready, Epoch, Route}, preparing,
             #{epoch := Epoch, target := Route} = D) ->
    notify(D, route_commit, Route),
    {next_state, committing, D, [{reply, From, ok}, switch_timer(D)]};
handle_event({call, From}, {acknowledge, Epoch}, committing,
             #{epoch := Epoch, target := Route} = D) ->
    notify(D, route_active, Route),
    {next_state, active, D#{active := Route, target := none, last_switch := now_ms(),
                          candidate := none}, [{reply, From, ok}]};
handle_event({call, From}, _, _, _) ->
    {keep_state_and_data, [{reply, From, {error, invalid_transition}}]};
handle_event(state_timeout, rollback, _, D) ->
    notify(D, route_rollback, maps:get(active, D)),
    {next_state, active, D#{target := none, candidate := none, last_switch := now_ms()}};
handle_event({timeout, evaluate}, tick, State, D) ->
    {Next, NextD, Actions} = evaluate(State, D),
    {next_state, Next, NextD, [tick(maps:get(options, D)) | Actions]};
handle_event(info, {'DOWN', Ref, process, _, _}, _, #{monitor := Ref}) ->
    {stop, normal};
handle_event(_, _, _, _) -> keep_state_and_data.

evaluate(State, D) when State =:= preparing; State =:= committing -> {State, D, []};
evaluate(State, #{options := O, active := Active} = D) ->
    Now = now_ms(),
    Target = case {healthy(p2p, D, Now), healthy(sfu, D, Now)} of
        {true, _} -> p2p;
        {false, true} -> sfu;
        _ -> none
    end,
    case Target =:= none orelse Target =:= Active of
        true -> {State, D#{candidate := none}, []};
        false ->
            D1 = case maps:get(candidate, D) of
                Target -> D;
                _ -> D#{candidate := Target, candidate_since := Now}
            end,
            Stable = Now - maps:get(candidate_since, D1) >= maps:get(sustain_ms, O),
            Cool = Now - maps:get(last_switch, D1) >= maps:get(cooldown_ms, O),
            case (Active =:= none orelse Stable) andalso Cool of
                true ->
                    D2 = D1#{target := Target, epoch := maps:get(epoch, D1) + 1},
                    notify(D2, route_prepare, Target),
                    {preparing, D2, [switch_timer(D2)]};
                false -> {State, D1, []}
            end
    end.

healthy(Route, #{metrics := Metrics, options := O}, Now) ->
    case maps:find(Route, Metrics) of
        {ok, #{received_at := At} = M} ->
            Now - At =< maps:get(fresh_ms, O) andalso beamvoice_network_metrics:healthy(M, O);
        error -> false
    end.
notify(#{owner := Owner, epoch := Epoch}, Event, Route) ->
    Owner ! {Event, self(), Epoch, Route}.
tick(O) -> {{timeout, evaluate}, maps:get(tick_ms, O), tick}.
switch_timer(#{options := O}) -> {state_timeout, maps:get(switch_timeout_ms, O), rollback}.
now_ms() -> erlang:monotonic_time(millisecond).
valid_options(O) ->
    lists:all(fun(Key) -> V = maps:get(Key, O), is_integer(V) andalso V > 0 end,
              [fresh_ms, sustain_ms, cooldown_ms, switch_timeout_ms, tick_ms, min_packets,
               max_rtt_ms, max_jitter_ms]) andalso
    is_number(maps:get(max_loss, O)) andalso maps:get(max_loss, O) >= 0 andalso
    maps:get(max_loss, O) =< 1.
