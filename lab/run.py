"""Bounded real-media acceptance runner. Writes evidence even when a scenario fails."""
import asyncio
import json
import os
import time
import traceback
from pathlib import Path

import aiohttp

HOSTS = [f"peer-{letter}" for letter in "abcdef"]
IP = {host: f"172.30.80.{index + 11}" for index, host in enumerate(HOSTS)}
RESULTS = []
RUN_FILE = Path("/results") / f"run-{time.time_ns()}.json"


def save_results():
    Path("/results").mkdir(exist_ok=True)
    content = json.dumps(RESULTS, indent=2)
    Path("/results/results.json").write_text(content)
    RUN_FILE.write_text(content)


async def server_metrics(http):
    token = "isolated-lab-only-credential-peer01-00000000"
    async with http.get("http://beamvoice-server:8080/metrics",
                        headers={"Authorization": f"Bearer {token}"}) as response:
        assert response.status == 200
        return {name: int(value) for name, value in
                (line.split(" ", 1) for line in (await response.text()).splitlines())}


async def server_netem(http, destination, profile):
    async with http.post("http://beamvoice-server:9001/command",
                         json={"destination": destination, "profile": profile},
                         timeout=aiohttp.ClientTimeout(total=10)) as response:
        assert response.status == 200, await response.text()


async def call(http, host, action, **data):
    async with http.post(f"http://{host}:9000/command", json={"action": action, **data}, timeout=aiohttp.ClientTimeout(total=30)) as response:
        if response.status != 200:
            raise AssertionError(f"{host} {action}: HTTP {response.status} {(await response.text())[:400]}")
        return await response.json()


async def until(http, host, user, predicate, timeout=25):
    deadline = time.monotonic() + timeout
    snapshot = {}
    while time.monotonic() < deadline:
        snapshot = await call(http, host, "snapshot", user=user)
        if predicate(snapshot):
            return snapshot
        await asyncio.sleep(0.5)
    raise AssertionError(f"condition timed out: user={snapshot.get('user')} "
                         f"active={snapshot.get('active')} "
                         f"rx={ {key: (value['frames'], value['nonzero'], snapshot['connections'].get(key, {}).get('dtls')) for key, value in snapshot.get('rx', {}).items()} } "
                         f"errors={snapshot.get('errors')}")


def receiving(snapshot, route, source, frames=20):
    key = f"{route}:{source}"
    connection, rx = snapshot["connections"].get(key, {}), snapshot["rx"].get(key, {})
    return connection.get("dtls") == "connected" and rx.get("nonzero", 0) >= frames


async def start(http, n=2, frame_ms=20, watermark=False):
    users = [(HOSTS[index % 6], f"peer{index + 1:02}") for index in range(n)]
    for host, user in users:
        await call(http, host, "start", user=user,
                   token=f"isolated-lab-only-credential-{user}-00000000",
                   frame_ms=frame_ms, watermark=watermark)
    return users


async def cleanup(http, users):
    for host, user in users:
        try:
            await call(http, host, "stop", user=user)
        except Exception:
            pass
    for host in HOSTS:
        await call(http, host, "netem", destination="172.30.80.2", profile="clear")
    await server_netem(http, IP[HOSTS[0]], "clear")
    await asyncio.sleep(1)


async def connect(http, users, sfu=True, p2p=True):
    if sfu:
        for host, user in users:
            await call(http, host, "offer", user=user, source=user, route="sfu")
        await asyncio.sleep(1)
        for host, user in users:
            for _, source in users:
                if user != source:
                    await call(http, host, "offer", user=user, source=source, route="sfu")
    if p2p:
        for index, (host, user) in enumerate(users):
            for _, source in users[index + 1:]:
                await call(http, host, "offer", user=user, source=source, route="p2p")


async def scenario(http, name, function):
    started = time.monotonic()
    try:
        evidence = await function()
        result = {"scenario": name, "status": "PASSOU", "evidence": evidence}
    except Exception as exc:
        result = {"scenario": name, "status": "FALHOU", "error": str(exc) or type(exc).__name__,
                  "trace": traceback.format_exc()}
    result["duration_seconds"] = time.monotonic() - started
    RESULTS.append(result)
    print(json.dumps({key: result[key] for key in ("scenario", "status", "duration_seconds", "error") if key in result}), flush=True)
    save_results()


async def pair(http, mode):
    users = await start(http)
    a, b = users
    try:
        if mode == "blocked":
            await call(http, a[0], "netem", destination=IP[b[0]], profile="blocked")
            await call(http, b[0], "netem", destination=IP[a[0]], profile="blocked")
        if mode == "sfu_degraded":
            await call(http, a[0], "netem", destination="172.30.80.2", profile="slow")
        if mode == "blocked":
            await connect(http, users, sfu=True, p2p=True)
        else:
            await connect(http, users, sfu=False, p2p=True)
            await until(http, b[0], b[1],
                        lambda s: receiving(s, "p2p", a[1]) and s["active"].get(a[1]) == "p2p",
                        timeout=45)
            await connect(http, users, sfu=True, p2p=False)
        route = "sfu" if mode == "blocked" else "p2p"
        initial = await until(http, b[0], b[1], lambda s: receiving(s, route, a[1]) and s["active"].get(a[1]) == route, timeout=45)
        if mode == "healthy":
            await asyncio.sleep(1)
            initial = await call(http, b[0], "snapshot", user=b[1])
            assert initial["rx"].get(f"sfu:{a[1]}", {}).get("frames", 0) == 0, "SFU forwarded an active P2P flow"
        if mode == "sfu_degraded":
            await until(http, b[0], b[1],
                        lambda s: s["connections"].get(f"sfu:{a[1]}", {}).get("dtls") == "connected",
                        timeout=45)
            await asyncio.sleep(2)
            initial = await call(http, b[0], "snapshot", user=b[1])
            assert initial["active"].get(a[1]) == "p2p"
            assert initial["rx"].get(f"sfu:{a[1]}", {}).get("frames", 0) == 0
        if mode in ("degraded", "recovery", "oscillation", "continuous"):
            await call(http, a[0], "netem", destination=IP[b[0]], profile="degraded")
            switched = await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "sfu" and receiving(s, "sfu", a[1]), timeout=45)
            if mode in ("recovery", "oscillation", "continuous"):
                await call(http, a[0], "netem", destination=IP[b[0]], profile="clear")
                before_restore = switched["rx"].get(f"p2p:{a[1]}", {}).get("played", 0)
                restored = await until(http, b[0], b[1],
                                       lambda s: s["active"].get(a[1]) == "p2p" and
                                       s["rx"].get(f"p2p:{a[1]}", {}).get("played", 0) >= before_restore + 20,
                                       timeout=60)
                return {"initial": initial, "switched": switched, "restored": restored, "limitation": "PCM counters verify decoded media; no cross-transport logical-frame identity yet"}
            return {"initial": initial, "switched": switched}
        return initial
    finally:
        await cleanup(http, users)


async def oscillation(http):
    users = await start(http)
    a, b = users
    try:
        await connect(http, users, sfu=False, p2p=True)
        await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "p2p"
                    and receiving(s, "p2p", a[1]), timeout=45)
        await connect(http, users, sfu=True, p2p=False)
        for _ in range(2):
            await call(http, a[0], "netem", destination=IP[b[0]], profile="degraded")
            await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "sfu"
                        and receiving(s, "sfu", a[1]), timeout=45)
            await call(http, a[0], "netem", destination=IP[b[0]], profile="clear")
            await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "p2p"
                        and receiving(s, "p2p", a[1]), timeout=45)
        stable = await call(http, b[0], "snapshot", user=b[1])
        switches = len([e for e in stable["events"] if e.get("type") == "route_active" and e.get("publisher") == a[1]])
        for _ in range(3):
            await call(http, a[0], "netem", destination=IP[b[0]], profile="degraded")
            await asyncio.sleep(0.4)
            await call(http, a[0], "netem", destination=IP[b[0]], profile="clear")
            await asyncio.sleep(0.4)
        final = await call(http, b[0], "snapshot", user=b[1])
        later = len([e for e in final["events"] if e.get("type") == "route_active" and e.get("publisher") == a[1]])
        assert final["active"].get(a[1]) == "p2p" and later == switches
        assert switches == 5, switches
        return {"route_activations": switches, "rapid_oscillation_extra_switches": later - switches,
                "final_route": final["active"].get(a[1]), "events": final["events"]}
    finally:
        await cleanup(http, users)


async def load(http, count, frame_ms=20, require_mixed=False):
    users = await start(http, count, frame_ms)
    try:
        # A ring bounds load at O(N); six-peer all-to-all is a separate acceptance case.
        if count == 6 and require_mixed:
            await connect(http, users, sfu=False)
            publisher, receiver = users[:2]
            await call(http, publisher[0], "offer", user=publisher[1],
                       source=publisher[1], route="sfu")
            await call(http, receiver[0], "offer", user=receiver[1],
                       source=publisher[1], route="sfu")
            expectations = [(host, user, source) for host, user in users for _, source in users if user != source]
        else:
            expectations = []
            for index, (host, user) in enumerate(users):
                source = users[(index + 1) % count][1]
                if count != 2 or index == 0:
                    await call(http, host, "offer", user=user, source=source, route="p2p")
                expectations.append((host, user, source))
        snapshots = []
        for host, user, source in expectations:
            snapshots.append(await until(http, host, user, lambda s, source=source: receiving(s, "p2p", source), timeout=40))
        mixed = None
        if count == 6 and require_mixed:
            a, b, c = users[:3]
            await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "p2p"
                        and s["active"].get(c[1]) == "p2p", timeout=35)
            await call(http, a[0], "netem", destination=IP[b[0]], profile="degraded")
            mixed = await until(http, b[0], b[1],
                                lambda s: s["active"].get(a[1]) == "sfu"
                                and s["active"].get(c[1]) == "p2p"
                                and receiving(s, "sfu", a[1]), timeout=45)
            await call(http, a[0], "netem", destination=IP[b[0]], profile="clear")
        before = await server_metrics(http)
        start_time = time.monotonic()
        await asyncio.sleep(5)
        after = await server_metrics(http)
        elapsed = time.monotonic() - start_time
        snapshots = [await call(http, host, "snapshot", user=user)
                     for host, user, _ in expectations]
        cpu_delta = after.get("beamvoice_cgroup_cpu_usage_usec", 0) - before.get("beamvoice_cgroup_cpu_usage_usec", 0)
        resources = {"sample_seconds": elapsed,
                     "cgroup_cpu_percent": 100 * cpu_delta / (elapsed * 1_000_000) if cpu_delta > 0 else None,
                     "cgroup_memory_bytes": after.get("beamvoice_cgroup_memory_current_bytes"),
                     "beam_memory_bytes": after.get("beamvoice_memory_bytes"),
                     "beam_processes": after.get("beamvoice_beam_processes"),
                     "rtp_received_per_second": (after.get("beamvoice_rtp_packets_received_total", 0)
                                                 - before.get("beamvoice_rtp_packets_received_total", 0)) / elapsed,
                     "rtp_forwarded_per_second": (after.get("beamvoice_rtp_packets_forwarded_total", 0)
                                                  - before.get("beamvoice_rtp_packets_forwarded_total", 0)) / elapsed,
                     "rtp_dropped_per_second": (after.get("beamvoice_rtp_packets_dropped_total", 0)
                                                - before.get("beamvoice_rtp_packets_dropped_total", 0)) / elapsed}
        return {"peers": count, "input_frame_ms": frame_ms,
                "topology": "mesh" if count == 6 else "ring",
                "received_flows": len(snapshots), "mixed_route": mixed,
                "resources": resources, "snapshots": snapshots}
    finally:
        await cleanup(http, users)


async def peer_failure(http):
    users = await start(http, 3)
    try:
        await connect(http, users, sfu=False)
        await until(http, users[1][0], users[1][1], lambda s: receiving(s, "p2p", users[2][1]))
        try:
            await call(http, users[0][0], "crash", user=users[0][1])
        except (aiohttp.ClientError, asyncio.TimeoutError):
            pass
        before = await call(http, users[1][0], "snapshot", user=users[1][1])
        await asyncio.sleep(2)
        after = await call(http, users[1][0], "snapshot", user=users[1][1])
        key = f"p2p:{users[2][1]}"
        assert after["rx"][key]["frames"] > before["rx"][key]["frames"]
        assert any(event.get("type") == "peer_left" and event.get("user") == users[0][1] for event in after["events"])
        async with http.get(f"http://{users[0][0]}:9000/health") as response:
            assert response.status == 200
        return after
    finally:
        await cleanup(http, users[1:])


async def media_failure(http):
    users = await start(http)
    a, b = users
    try:
        await connect(http, users, sfu=False, p2p=True)
        await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "p2p"
                    and receiving(s, "p2p", a[1]), timeout=45)
        await connect(http, users, sfu=True, p2p=False)
        await until(http, b[0], b[1], lambda s: s["connections"].get(f"sfu:{a[1]}", {}).get("dtls") == "connected")
        before = await call(http, b[0], "snapshot", user=b[1])
        await call(http, b[0], "fault_media", user=b[1])
        failed = await until(http, b[0], b[1],
                             lambda s: any(e.get("type") == "media_failed" for e in s["events"]), timeout=10)
        await asyncio.sleep(2)
        preserved = await call(http, b[0], "snapshot", user=b[1])
        assert preserved["active"].get(a[1]) == "p2p"
        assert preserved["rx"][f"p2p:{a[1]}"]["frames"] >= before["rx"][f"p2p:{a[1]}"]["frames"] + 20
        await call(http, b[0], "offer", user=b[1], source=b[1], route="sfu")
        await call(http, b[0], "offer", user=b[1], source=a[1], route="sfu")
        await until(http, b[0], b[1],
                    lambda s: s["connections"].get(f"sfu:{a[1]}", {}).get("dtls") == "connected", timeout=30)
        await call(http, a[0], "netem", destination=IP[b[0]], profile="degraded")
        recovered = await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "sfu"
                                and receiving(s, "sfu", a[1]), timeout=45)
        return {"media_failed_events": sum(e.get("type") == "media_failed" for e in failed["events"]),
                "p2p_frames_after_media_failure": preserved["rx"][f"p2p:{a[1]}"]["frames"] - before["rx"][f"p2p:{a[1]}"]["frames"],
                "recovered_route": recovered["active"].get(a[1])}
    finally:
        await cleanup(http, users)


async def continuous(http):
    users = await start(http, watermark=True)
    a, b = users
    try:
        await connect(http, users, sfu=False, p2p=True)
        await until(http, b[0], b[1], lambda s: s["active"].get(a[1]) == "p2p"
                    and len([p for p in s["playout"] if p["source"] == a[1]]) >= 60,
                    timeout=45)
        await connect(http, users, sfu=True, p2p=False)
        await call(http, a[0], "netem", destination=IP[b[0]], profile="degraded")
        switched = await until(http, b[0], b[1],
                               lambda s: s["active"].get(a[1]) == "sfu"
                               and len([p for p in s["playout"] if p["source"] == a[1] and p["route"] == "sfu"]) >= 40,
                               timeout=45)
        await call(http, a[0], "netem", destination=IP[b[0]], profile="clear")
        returned = await until(http, b[0], b[1],
                               lambda s: s["active"].get(a[1]) == "p2p"
                               and len([p for p in s["playout"] if p["source"] == a[1] and p["at"] > switched["events"][-1]["at"] and p["route"] == "p2p"]) >= 40,
                               timeout=45)
        await asyncio.sleep(11)
        await server_netem(http, IP[b[0]], "blocked")
        await call(http, a[0], "netem", destination=IP[b[0]], profile="degraded")
        rollback = await until(http, b[0], b[1],
                               lambda s: any(e.get("type") == "route_rollback" for e in s["events"]),
                               timeout=25)
        assert rollback["active"].get(a[1]) == "p2p"
        await server_netem(http, IP[b[0]], "clear")
        await call(http, a[0], "netem", destination=IP[b[0]], profile="clear")
        await asyncio.sleep(2)
        final = await call(http, b[0], "snapshot", user=b[1])
        played = [p for p in final["playout"] if p["source"] == a[1]]
        assert len(played) >= 120, "watermark not decoded from real Opus audio"
        deltas = [(right["id"] - left["id"]) % 256 for left, right in zip(played, played[1:])]
        duplicates = sum(d == 0 for d in deltas)
        out_of_order = sum(d > 128 for d in deltas)
        missing = sum(d - 1 for d in deltas if 1 < d <= 128)
        gaps = sorted((right["at"] - left["at"]) * 1000 for left, right in zip(played, played[1:]))
        gap_percentiles = {f"p{p}": gaps[min(len(gaps) - 1, int(p / 100 * len(gaps)))]
                           for p in (50, 95, 99)}
        switch_durations = []
        for event in final["events"]:
            if event.get("type") == "route_prepare" and event.get("publisher") == a[1]:
                active = next((candidate for candidate in final["events"]
                               if candidate.get("type") == "route_active"
                               and candidate.get("epoch") == event["epoch"]
                               and candidate.get("publisher") == a[1]), None)
                if active:
                    switch_durations.append({"route": active["route"],
                                             "milliseconds": (active["at"] - event["at"]) * 1000})
        assert duplicates == 0 and out_of_order == 0, (
            f"decoded={len(played)} duplicates={duplicates} out_of_order={out_of_order} "
            f"missing={missing} first_ids={[p['id'] for p in played[:20]]} "
            f"last_ids={[p['id'] for p in played[-20:]]}")
        assert final["active"].get(a[1]) == "p2p"
        return {"decoded_frames": len(played), "missing_frames": missing,
                "duplicate_frames": duplicates, "out_of_order_frames": out_of_order,
                "playout_drops": final["playout_drops"],
                "max_playout_gap_ms": gaps[-1],
                "playout_gap_percentiles_ms": gap_percentiles,
                "switch_durations": switch_durations,
                "route_activations": [e["route"] for e in final["events"] if e.get("type") == "route_active"],
                "rollback_events": sum(e.get("type") == "route_rollback" for e in final["events"]),
                "final_route": final["active"].get(a[1])}
    finally:
        await cleanup(http, users)


async def invalid(http):
    url = "http://beamvoice-server:8080/ws"
    async with http.ws_connect(url) as ws:
        await ws.send_json({"type": "join", "room": "lab", "user": "forged"})
        reply = await ws.receive_json(timeout=5)
        assert reply.get("type") == "error", reply
    async with http.ws_connect(url) as ws:
        try:
            for _ in range(90):
                await ws.send_str("{")
        except ConnectionResetError:
            pass
        messages = []
        async for frame in ws:
            messages.append(frame.type.name)
            if len(messages) > 80:
                raise AssertionError("flood not bounded")
        # The peer may reset TCP while the server is sending its rate-limit close frame.
        assert ws.close_code in (1008, 1000, 1006), ws.close_code
    return {"unauthorized_join": reply, "flood_close_code": ws.close_code}


async def main():
    async with aiohttp.ClientSession() as http:
        for host in HOSTS:
            for attempt in range(90):
                try:
                    async with http.get(f"http://{host}:9000/health") as response:
                        if response.status == 200:
                            break
                except aiohttp.ClientError:
                    pass
                await asyncio.sleep(1)
            else:
                raise RuntimeError(f"worker unavailable: {host}")
        for attempt in range(90):
            try:
                async with http.get("http://beamvoice-server:8080/health") as response:
                    if response.status == 200:
                        break
            except aiohttp.ClientError:
                pass
            await asyncio.sleep(1)
        for attempt in range(30):
            try:
                async with http.get("http://beamvoice-server:9001/health") as response:
                    if response.status == 200:
                        break
            except aiohttp.ClientError:
                pass
            await asyncio.sleep(1)
        else:
            raise RuntimeError("server network emulator unavailable")
        selected = os.environ.get("SCENARIOS", "T01,T02,T03,T04,T05,T07,T10").split(",")
        for name, mode in [("T01", "healthy"), ("T02", "blocked"), ("T03", "degraded"), ("T04", "sfu_degraded"), ("T05", "recovery")]:
            if name in selected:
                await scenario(http, name, lambda mode=mode: pair(http, mode))
        if "T06" in selected:
            await scenario(http, "T06", lambda: oscillation(http))
        if "T07" in selected:
            await scenario(http, "T07", lambda: load(http, 6, require_mixed=True))
        if "T08" in selected:
            await scenario(http, "T08", lambda: peer_failure(http))
        if "T09" in selected:
            await scenario(http, "T09", lambda: media_failure(http))
        if "T12" in selected:
            await scenario(http, "T12", lambda: continuous(http))
        if "T10" in selected:
            await scenario(http, "T10", lambda: invalid(http))
        if "T11" in selected:
            for count in (2, 6, 12, 24):
                for frame_ms in (10, 20):
                    await scenario(http, f"T11-{count}-{frame_ms}ms", lambda count=count, frame_ms=frame_ms: load(http, count, frame_ms))
        save_results()
        return 1 if any(r["status"] == "FALHOU" or (r["scenario"] in selected and r["status"] != "PASSOU") for r in RESULTS) else 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
