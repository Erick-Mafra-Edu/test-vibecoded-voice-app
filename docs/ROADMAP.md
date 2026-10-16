# Architecture and milestones

## Goals
- Up to 6 concurrent users initially, on a 2-vCPU server.
- Erlang/OTP control plane; Opus/SRTP/UDP media, P2P when favorable, SFU fallback.
- Measured end-to-end latency, jitter, packet loss and route switch time.

## Milestone 0 — foundation (included)
- OTP app, dynamically supervised rooms, registry, bounded Cowboy WebSocket, health endpoint, route policy, EUnit and Common Test suites.
- Docker multi-stage build, GitHub Actions CI and GHCR publication.

## Milestone 1 — secure signaling
- Signed authentication, per-room ACL, user identity from token rather than JSON payload.
- WSS and message protocol versioning.
- SDP offer/answer, ICE candidate exchange; integration tests with 2 clients.
- Signed authentication and ACL-aware reconnect semantics remain; room cleanup and basic rate/resource limits are included.

## Milestone 2 — BEAM media integration
- Create an Elixir umbrella/mix application for ex_webrtc or a dedicated media process.
- Explicit adapter contract across Erlang and Elixir; pin compatible OTP/Elixir versions.
- Opus mono, initially 10-20ms frames; SRTP; no server-side transcoding.
- Validate 2-user calls, 6-user SFU and TURN fallback.

## Milestone 3 — hybrid routing
- Start SFU-first, then P2P for eligible pairs.
- Collect packet loss, jitter, route RTT and audio playout estimates.
- Implement hysteresis and cooldown, make-before-break, SSRC/sequence continuity.
- Ensure each remote stream is played exactly once.

## Milestone 4 — production readiness
- Prometheus/OpenTelemetry, load and fault-injection tests, CPU limits.
- Test 6, 12 and 24 users, geographic RTT profiles, NAT/firewall failures.
- Deployment manifests, secret management, tagged releases and rollback.

## Non-goals initially
- Screen sharing, chat history, video, federation, multiple media regions.
