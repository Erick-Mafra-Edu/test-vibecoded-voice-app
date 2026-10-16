# Estado inicial da implementação híbrida

Branch `feature/hybrid-webrtc-routing`, criada a partir de `main` preservando o
hardening local. O commit base remoto era `b17c350`; o hardening foi registrado
localmente antes da integração de mídia. Nenhum push faz parte desta tarefa.

Inspecionados todos os módulos de `src/`, testes de `test/`, configurações rebar,
Dockerfile, workflows, README e roadmap. Nenhum AGENTS.md encontrado no projeto.

Existia: Cowboy HTTP/WebSocket, join/members, salas monitoradas e supervisionadas,
limites, allowlist Origin e política pura sobre latências hipotéticas.
Não existia: identidade autenticada, ACL, SDP/ICE, mídia, SFU, cliente WebRTC ou netem.
O behaviour de mídia tinha somente declarações de callbacks, sem implementação.

Baseline executada antes de editar: `rebar3 compile && rebar3 eunit && rebar3 ct`
em Docker local, quota 2 CPUs/512 MiB: compilação aprovada, **16 EUnit e 2 CT passaram**.
Dependências: Cowboy 2.19.0, Cowlib 2.21.0, Ranch 2.3.0, JSX 3.1.0; OTP 27,
rebar3 3.26.0. Build e smoke anteriores estavam descritos em `docs/audit/`.

Os relatórios de auditoria são históricos; as evidências desta implementação ficam
em `TEST_RESULTS.md` e não substituem retrospectivamente os resultados anteriores.

## Decisão tecnológica

Integração Elixir/Erlang na mesma VM via dependência Mix local com manager rebar3.
ExWebRTC negocia ICE, verifica fingerprints DTLS e protege/desprotege SRTP via
bibliotecas mantidas; o código de aplicação só encaminha RTP já autenticado.
Não há motivo demonstrado para adicionar um processo de mídia externo.

ExWebRTC oferece transportes, RTP e RTCP, mas **não uma SFU completa**: autorização,
associação de tracks, assinaturas, limites, supervisão e seleção de rota são
responsabilidades implementadas pelo BeamVoice. Membrane RTC Engine seria uma
alternativa de SFU BEAM de maior escopo, dispensável para o primeiro áudio Opus.

Fontes consultadas: [ExWebRTC forwarding](https://ex-webrtc.hexdocs.pm/forwarding.html),
[PeerConnection](https://ex-webrtc.hexdocs.pm/ExWebRTC.PeerConnection.html).
