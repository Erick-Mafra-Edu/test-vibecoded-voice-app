# BeamVoice (experimental)

Experimental Erlang/OTP control plane with a BEAM WebRTC media adapter.
ExWebRTC provides ICE/DTLS-SRTP/Opus transports; the application forwards RTP
between authorized SFU sessions and coordinates P2P/SFU routes per recipient.
The Docker lab uses independent aiortc clients. See
[test results](docs/testing/TEST_RESULTS.md) before treating any scenario as verified.

## Requirements
- Erlang/OTP 27, rebar3, Elixir 1.18, and Docker Compose v2 for the network lab.

## Local development
```sh
rebar3 compile
rebar3 eunit
rebar3 ct
cd media
BEAMVOICE_ALLOW_INSECURE=true mix test
```

## Docker
```sh
docker build -t beamvoice:dev .
docker run --rm --cpus=2 --memory=512m --read-only --tmpfs /tmp \
  --cap-drop=ALL --security-opt no-new-privileges \
  -e BEAMVOICE_CREDENTIALS_FILE=/run/credentials.json \
  -v "$PWD/credentials.json:/run/credentials.json:ro" \
  -e BEAMVOICE_TLS_CERT=/run/tls.crt -e BEAMVOICE_TLS_KEY=/run/tls.key \
  -v "$PWD/tls.crt:/run/tls.crt:ro" -v "$PWD/tls.key:/run/tls.key:ro" \
  -p 127.0.0.1:8080:8080 beamvoice:dev
curl --cacert tls.crt https://127.0.0.1:8080/health
```

## WebSocket protocol
Connect to `wss://localhost:8080/ws` and send an opaque bearer token provisioned
in the credentials JSON file:
```json
{"type":"auth","token":"replace-with-an-individual-32-byte-or-longer-token"}
```
Then `{"type":"join","room":"friends"}`. The server derives the user ID from
the token and checks the room ACL. Credential file format is an array such as
`[{"token":"...","user":"alice","rooms":["friends"]}]`; do not commit
production tokens. See `lab/credentials.lab.json` for **test-only** fixture IDs.
`members`, P2P `signal`, SFU `media_offer`/`media_candidate` and route telemetry
are documented in the [client contract](docs/client/CLIENT_CONTRACT.md) and
[routing](docs/architecture/HYBRID_ROUTING.md).

Browser origins default to `http://localhost:8080,http://127.0.0.1:8080`. Set
`ALLOWED_ORIGINS` to a comma-separated exact allowlist when using another origin.
Connections are limited to 32, messages to 20 KiB and 32 messages/second per
WebSocket, rooms to 16, and participants to 24 per room. The room/connection
defaults are application environment values and should only be raised after load testing.
Empty rooms expire after a one-second grace period so an in-flight reconnect can reuse them.

## Design
- `beamvoice_room`: a `gen_server` per room; monitors client processes.
- `beamvoice_room_sup`: supervises temporary room workers; empty rooms terminate.
- `beamvoice_room_registry`: serializes room creation and rebuilds its index after a restart.
- `beamvoice_route_coordinator`: per directed flow state machine with hysteresis and rollback.
- `BeamVoice.Media.Session`: per participant WebRTC transports with gated RTP forwarding.
- `beamvoice_ws_handler`: authenticated SDP/ICE signaling and route coordination.

## Network lab
```sh
docker compose -f compose.test.yaml up --build --abort-on-container-exit --exit-code-from test-runner
```
The local-only lab uses synthetic Opus media over real ICE/DTLS-SRTP connections
and destination-specific `tc netem`. Results are written to
`lab/results/results.json`. See [network lab](docs/testing/NETWORK_LAB.md),
[test matrix](docs/testing/TEST_MATRIX.md), and
[pipeline limitations](docs/architecture/WEBRTC_MEDIA_PIPELINE.md).

## Production gaps
TURN/NAT deployment, browser interoperability, frame-level continuity across
route switches, six simultaneous SFU-fed peers, and calibrated VPS latency/stress
results require further work. The local T12 had a 477 ms maximum playout gap;
the route change is functional, not inaudible.
Cowlib 2.21.0 currently reports a medium advisory in Mix; track an upstream fix.
Plain HTTP is refused unless `BEAMVOICE_ALLOW_INSECURE=true` is set for an
isolated lab. Never expose lab credentials or peer control APIs publicly.

## CI/CD
- Pull requests: compile, EUnit, Common Test, container build and basic network lab.
- Tags `v*`: publish to GHCR. No automatic production deployment; require an environment and approval before adding it.
- CI configuration is provided; local Docker evidence is in `TEST_RESULTS.md`.

See `docs/ROADMAP.md` for milestones.
