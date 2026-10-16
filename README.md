# BeamVoice (experimental)

An Erlang/OTP foundation for a private low-latency voice system. **This is a signaling MVP, not yet a working VoIP service.** Media, authentication, encryption, ICE, and SFU are not implemented.

## Requirements
- Erlang/OTP 27 and rebar3, or Docker for building/running

## Local development
```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 shell
```

## Docker
```sh
docker build -t beamvoice:dev .
docker run --rm --cpus=2 --memory=512m --read-only --tmpfs /tmp \
  --cap-drop=ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8080:8080 beamvoice:dev
curl http://127.0.0.1:8080/health
```

## WebSocket prototype
Connect to `ws://localhost:8080/ws` and send:
```json
{"type":"join","room":"friends","user":"alice"}
```
Then `{"type":"members"}` to list users. **No authentication**: do not expose publicly. `user` is an untrusted client-supplied identifier.

Browser origins default to `http://localhost:8080,http://127.0.0.1:8080`. Set
`ALLOWED_ORIGINS` to a comma-separated exact allowlist when using another origin.
Connections are limited to 128, messages to 4 KiB and 20 messages/second per
WebSocket, rooms to 100, and participants to 24 per room. The room/connection
defaults are application environment values and should only be raised after load testing.
Empty rooms expire after a one-second grace period so an in-flight reconnect can reuse them.

## Design
- `beamvoice_room`: a `gen_server` per room; monitors client processes.
- `beamvoice_room_sup`: supervises temporary room workers; empty rooms terminate.
- `beamvoice_room_registry`: serializes room creation and rebuilds its index after a restart.
- `beamvoice_route_policy`: pure function for route selection; inputs are hypothetical measured latencies.
- `beamvoice_media_adapter`: behaviour for a future BEAM-based WebRTC transport.
- `beamvoice_ws_handler`: limited signaling demonstration; no SDP/ICE forwarding yet.

## Security / production blockers
- Replace client-supplied identity with signed authentication and enforce per-room ACLs.
- Use TLS/WSS and secure media (DTLS-SRTP); never send unencrypted voice over public networks.
- Implement ICE/STUN/TURN, RTP forwarding, Opus tracks, packet continuity and route failover.
- Validate input, rate limit, prevent impersonation and add observability.
- Terminate TLS at a trusted reverse proxy or add Cowboy TLS before any public exposure.

## CI/CD
- Pull requests: compile, EUnit, Common Test, container build.
- Tags `v*`: publish to GHCR. No automatic production deployment; require an environment and approval before adding it.
- CI workflows are provided but **have not been executed in this environment**.

See `docs/ROADMAP.md` for milestones.
