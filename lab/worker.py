"""Isolated lab control API. Never expose this unauthenticated API publicly."""
import asyncio
import json
import math
import os
import time
from collections import deque
from fractions import Fraction

import aiohttp
import numpy as np
from aiohttp import web
from aiortc import AudioStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription, RTCRtpSender
from aiortc.sdp import candidate_from_sdp
from av import AudioFrame


class Tone(AudioStreamTrack):
    def __init__(self, frequency, frame_ms=20, epoch=None, watermark=False):
        super().__init__()
        self.frequency, self.samples, self.count = frequency, frame_ms * 48, 0
        self.start = time.monotonic()
        self.epoch, self.watermark, self.last_slot = epoch, watermark, -1

    async def recv(self):
        pts = self.count * self.samples
        if self.watermark:
            slot = max(self.last_slot + 1, int((time.monotonic() - self.epoch) * 48000 / self.samples))
            await asyncio.sleep(max(0, self.epoch + slot * self.samples / 48000 - time.monotonic()))
            self.last_slot = slot
            marker = slot % 256
            low, high = 600 + 100 * (marker & 15), 2800 + 100 * (marker >> 4)
            phase = (np.arange(self.samples) + pts) / 48000
            data = (4000 * np.sin(2 * math.pi * low * phase)
                    + 4000 * np.sin(2 * math.pi * high * phase)).astype(np.int16)
        else:
            await asyncio.sleep(max(0, self.start + pts / 48000 - time.monotonic()))
            data = (6000 * np.sin(2 * math.pi * self.frequency * (np.arange(self.samples) + pts) / 48000)).astype(np.int16)
        frame = AudioFrame.from_ndarray(data.reshape(1, -1), format="s16", layout="mono")
        frame.sample_rate, frame.pts, frame.time_base = 48000, pts, Fraction(1, 48000)
        self.count += 1
        return frame


def decode_marker(frame):
    if frame.sample_rate != 48000 or frame.samples != 960:
        return None
    spectrum = np.abs(np.fft.rfft(frame.to_ndarray().reshape(-1).astype(np.float64)))
    low = np.arange(12, 44, 2)
    high = np.arange(56, 88, 2)
    if max(spectrum[low]) < 50000 or max(spectrum[high]) < 50000:
        return None
    return int(np.argmax(spectrum[low]) + 16 * np.argmax(spectrum[high]))


class Peer:
    def __init__(self, user, token, room, frame_ms, watermark=False):
        self.user, self.token, self.room, self.frame_ms = user, token, room, frame_ms
        self.watermark, self.playout = watermark, []
        self.last_marker = {}
        self.playout_drops = {"duplicate": 0, "stale": 0, "unreadable": 0}
        self.pcs, self.rx, self.active, self.pending = {}, {}, {}, {}
        self.gaps, self.latest_metrics = {}, {}
        self.events, self.tasks, self.errors = [], [], []
        self.started = time.monotonic()
        self.sequence = 0

    async def start(self):
        self.http = aiohttp.ClientSession()
        self.ws = await self.http.ws_connect(os.environ.get("SIGNAL_URL", "http://beamvoice-server:8080/ws"))
        await self.send(type="auth", token=self.token)
        reply = await self.ws.receive_json(timeout=10)
        assert reply.get("type") == "authenticated", reply
        await self.send(type="join", room=self.room)
        reply = await self.ws.receive_json(timeout=10)
        assert reply.get("type") == "joined", reply
        self.tasks += [asyncio.create_task(self.messages()), asyncio.create_task(self.metrics())]

    async def send(self, **message):
        await self.ws.send_json(message)

    def connection(self, key, send_audio):
        pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.pcs[key] = pc
        transceiver = pc.addTransceiver(
            Tone(440 + sum(map(ord, self.user)) % 400, self.frame_ms,
                 self.started, self.watermark) if send_audio else "audio",
            direction="sendonly" if send_audio else "recvonly")
        transceiver.setCodecPreferences([c for c in RTCRtpSender.getCapabilities("audio").codecs if c.mimeType.lower() == "audio/opus"])
        @pc.on("track")
        def track_received(track):
            self.tasks.append(asyncio.create_task(self.consume(key, track)))
        return pc

    async def consume(self, key, track):
        state = self.rx.setdefault(key, {"frames": 0, "nonzero": 0, "last": None, "max_gap_ms": 0, "played": 0, "pts_regressions": 0, "last_pts": None})
        try:
            while True:
                frame = await track.recv()
                now = time.monotonic()
                if state["last"]:
                    gap = (now - state["last"]) * 1000
                    state["max_gap_ms"] = max(state["max_gap_ms"], gap)
                    self.gaps.setdefault(key, deque(maxlen=1000)).append(gap)
                if state["last_pts"] is not None and frame.pts <= state["last_pts"]:
                    state["pts_regressions"] += 1
                state.update(last=now, last_pts=frame.pts, frames=state["frames"] + 1)
                state["nonzero"] += int(np.abs(frame.to_ndarray().astype(np.int32)).max() > 50)
                route, source = key.split(":", 1)
                if self.active.get(source) == route:
                    if self.watermark:
                        marker = decode_marker(frame)
                        if marker is None:
                            self.playout_drops["unreadable"] += 1
                        else:
                            previous = self.last_marker.get(source)
                            delta = (marker - previous) % 256 if previous is not None else 1
                            if delta == 0:
                                self.playout_drops["duplicate"] += 1
                            elif delta > 128:
                                self.playout_drops["stale"] += 1
                            else:
                                self.last_marker[source] = marker
                                state["played"] += 1
                                self.playout.append({"id": marker, "route": route,
                                                     "source": source, "at": now - self.started})
                                self.playout = self.playout[-3000:]
                    else:
                        state["played"] += 1
                pending = self.pending.get(source)
                if pending and pending["route"] == route and not pending.get("ready"):
                    pending["ready"] = True
                    await self.send(type="route_ready", publisher=source, epoch=pending["epoch"], route=route)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            if pc := self.pcs.get(key):
                if pc.connectionState != "closed":
                    self.errors.append(f"receive {key}: {type(exc).__name__}")

    async def offer(self, source, route):
        key = f"{route}:{source}"
        if key in self.pcs:
            await self.pcs.pop(key).close()
        pc = self.connection(key, route == "p2p" or source == self.user)
        if route == "p2p":
            pc.getTransceivers()[0].direction = "sendrecv"
        await pc.setLocalDescription(await pc.createOffer())
        description = {"type": pc.localDescription.type, "sdp": pc.localDescription.sdp}
        if route == "p2p":
            await self.send(type="signal", to=source, description=description)
        else:
            await self.send(type="media_offer", transport=source, publisher=source, sdp=description)

    async def messages(self):
        async for frame in self.ws:
            if frame.type != aiohttp.WSMsgType.TEXT:
                continue
            message = json.loads(frame.data)
            kind = message.get("type")
            self.events.append({"at": time.monotonic() - self.started, **{k: v for k, v in message.items() if k not in ("sdp", "candidate", "description")}})
            self.events = self.events[-200:]
            try:
                if kind == "signal" and "description" in message:
                    source, description = message["from"], message["description"]
                    key = f"p2p:{source}"
                    pc = self.pcs.get(key) or self.connection(key, True)
                    pc.getTransceivers()[0].direction = "sendrecv"
                    await pc.setRemoteDescription(RTCSessionDescription(**description))
                    if description["type"] == "offer":
                        await pc.setLocalDescription(await pc.createAnswer())
                        await self.send(type="signal", to=source, description={"type": "answer", "sdp": pc.localDescription.sdp})
                elif kind == "media_answer":
                    await self.pcs[f"sfu:{message['publisher']}"].setRemoteDescription(RTCSessionDescription(**message["sdp"]))
                elif kind == "media_candidate":
                    value = message["candidate"]
                    if value.get("candidate"):
                        candidate = candidate_from_sdp(value["candidate"].removeprefix("candidate:"))
                        candidate.sdpMid, candidate.sdpMLineIndex = value.get("sdpMid"), value.get("sdpMLineIndex")
                        await self.pcs[f"sfu:{message['publisher']}"].addIceCandidate(candidate)
                elif kind == "route_prepare":
                    self.pending[message["publisher"]] = message
                elif kind == "route_commit":
                    self.active[message["publisher"]] = message["route"]
                    await self.send(type="route_ack", publisher=message["publisher"], epoch=message["epoch"])
                elif kind == "error":
                    self.errors.append(message)
            except Exception as exc:
                self.errors.append(f"{kind}: {exc}")

    async def metrics(self):
        previous = {}
        while True:
            await asyncio.sleep(1)
            self.sequence += 1
            for key, pc in list(self.pcs.items()):
                route, source = key.split(":", 1)
                if source == self.user:
                    continue
                report = await pc.getStats()
                inbound = next((s for s in report.values() if s.type == "inbound-rtp"), None)
                received, lost, jitter = (inbound.packetsReceived, inbound.packetsLost, inbound.jitter / 48) if inbound else (0, 0, 0)
                prev_r, prev_l = previous.get(key, (0, 0))
                packets, missing = max(0, received - prev_r), max(0, lost - prev_l)
                previous[key] = received, lost
                remote = next((s for s in report.values() if s.type == "remote-inbound-rtp"), None)
                dtls = pc.getTransceivers()[0].receiver.transport.state
                measured_rtt = getattr(remote, "roundTripTime", None)
                metrics = {"sequence": self.sequence, "window_ms": 1000,
                           "rtt_ms": measured_rtt * 1000 if measured_rtt is not None else None,
                           "jitter_ms": jitter, "loss": missing / max(1, packets + missing),
                           "packets": packets,
                           "ice": "connected" if pc.iceConnectionState in ("connected", "completed") else "disconnected",
                           "dtls": "connected" if dtls == "connected" else "connecting"}
                self.latest_metrics[key] = metrics
                await self.send(type="route_metrics", publisher=source, route=route, metrics=metrics)

    async def snapshot(self):
        rx = {key: {**value, "callback_gap_ms":
              dict(zip(("p50", "p95", "p99"), map(float, np.percentile(list(self.gaps[key]), (50, 95, 99)))))
              if self.gaps.get(key) else None} for key, value in self.rx.items()}
        return {"user": self.user, "active": self.active, "rx": rx,
                "route_metrics": self.latest_metrics, "events": self.events,
                "errors": self.errors, "playout": self.playout,
                "playout_drops": self.playout_drops,
                "connections": {key: {"connection": pc.connectionState,
                "ice": pc.iceConnectionState,
                "dtls": pc.getTransceivers()[0].receiver.transport.state}
                for key, pc in self.pcs.items()}}

    async def close(self):
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        try:
            await asyncio.gather(*(pc.close() for pc in self.pcs.values()), return_exceptions=True)
        finally:
            if hasattr(self, "ws"):
                await self.ws.close()
            if hasattr(self, "http"):
                await self.http.close()


peers = {}


async def command(request):
    body = await request.json()
    action, user = body["action"], body.get("user")
    if action == "start":
        assert len(peers) < 24 and user not in peers
        peer = Peer(user, body["token"], body.get("room", "lab"),
                    body.get("frame_ms", 20), body.get("watermark", False))
        peers[user] = peer
        try:
            await peer.start()
        except Exception:
            peers.pop(user, None)
            await peer.close()
            raise
    elif action == "offer":
        await peers[user].offer(body["source"], body["route"])
    elif action == "stop":
        await peers.pop(user).close()
    elif action == "crash":
        os._exit(73)
    elif action == "fault_media":
        await peers[user].send(type="lab_kill_media")
    elif action == "snapshot":
        return web.json_response(await peers[user].snapshot())
    elif action == "netem":
        from netem import configure
        await configure(body["destination"], body.get("profile", "clear"))
    else:
        raise web.HTTPBadRequest()
    return web.json_response({"ok": True})


app = web.Application(client_max_size=16384)
app.router.add_post("/command", command)
app.router.add_get("/health", lambda _: web.json_response({"ok": True}))
if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=9000)
