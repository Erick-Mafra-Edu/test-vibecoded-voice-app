# Architecture review

> Revisão histórica da baseline. Para a arquitetura implementada e verificada
> nesta branch, ver `docs/architecture/` e `docs/testing/TEST_RESULTS.md`.

## O que este repositório faz

BeamVoice é uma aplicação OTP experimental de sinalização por WebSocket. Um cliente pode
entrar em uma sala e consultar os identificadores presentes. Não há áudio ou WebRTC; a
política P2P/SFU é uma função pura sobre métricas hipotéticas e o adaptador de mídia é
somente um behaviour sem implementação.

## Inventário real

| Estado | Funcionalidade | Evidência |
|---|---|---|
| Implementada | aplicação/supervisão OTP | `beamvoice_app`, `beamvoice_sup` |
| Implementada | `/health` HTTP | `beamvoice_health_handler` |
| Implementada | upgrade WebSocket, join e members | `beamvoice_ws_handler` |
| Implementada | sala por processo, monitores e limpeza | `beamvoice_room` |
| Implementada | registro e supervisor dinâmico de salas | `beamvoice_room_registry`, `beamvoice_room_sup` |
| Implementada | limites de conexão/frame/flood/salas/membros | `beamvoice_http`, `beamvoice_ws_handler`, app env |
| Simulada | decisão P2P versus SFU por números fornecidos | `beamvoice_route_policy` |
| Contrato somente | adaptador de transporte de mídia | `beamvoice_media_adapter` |
| Ausente | autenticação, ACL, sessão persistente | nenhum módulo |
| Ausente | SDP, ICE/STUN/TURN, WebRTC, RTP/RTCP, Opus, DTLS-SRTP, SFU | nenhum módulo |
| Ausente | banco, ETS, cluster/distribuição Erlang, observabilidade | nenhum módulo |

O README está alinhado ao código ao chamá-lo de MVP sem VoIP. O roadmap descreve WebRTC
e mídia como marcos futuros, não como entrega atual.

## Módulos e responsabilidades

- `beamvoice_app`: callback mínimo da aplicação.
- `beamvoice_sup`: supervisor raiz `one_for_one`.
- `beamvoice_room_sup`: adiciona filhos temporários para salas. Uma sala com falha não
  reinicia com estado vazio silenciosamente; clientes precisam reconectar.
- `beamvoice_room_registry`: serializa criação, limita quantidade, monitora salas e
  reconstrói o índice após reinício.
- `beamvoice_room`: dono do mapa de membros de uma sala e seus monitores de sessão.
- `beamvoice_http`: configura listener Ranch/Cowboy e limites HTTP.
- `beamvoice_ws_handler`: fronteira não confiável; valida origin, tamanho, taxa, JSON e estado da conexão.
- `beamvoice_health_handler`: liveness simples.
- `beamvoice_route_policy`: função pura sem efeito no tráfego atual.
- `beamvoice_media_adapter`: behaviour futuro, sem implementação.

## Árvore de supervisão

```text
beamvoice_sup (one_for_one, 5 reinícios/10 s)
├── beamvoice_room_sup (supervisor)
│   └── beamvoice_room[RoomId] (worker temporário, 0..100)
├── beamvoice_room_registry (worker permanente)
└── beamvoice_http / Ranch listener (worker permanente)
    └── processos de conexão Cowboy/Ranch
```

O `one_for_one` é apropriado: falha no listener não deve reiniciar salas; falha no
registro não deve derrubar salas. Filhos de sala `temporary` evitam restart storm e
ressurreição de estado vazio. O registro recupera os filhos existentes do supervisor.

## Fluxo de dados e estado

1. TCP chega à porta configurada (8080 por padrão), em HTTP claro.
2. `/ws` valida `Origin`; Cowboy conclui o upgrade e cria um processo por conexão.
3. O handler limita taxa/frame, decodifica JSON e aceita exatamente `join` ou `members`.
4. `join` pede ao registro uma sala. O registro cria no supervisor ou devolve o PID existente.
5. A sala monitora o PID da sessão e armazena `UserId => {SessionPid, MonitorRef}`.
6. `members` consulta diretamente a sala; o registro não está no caminho.
7. Desconexão gera `DOWN` ou `terminate/3`; o último membro encerra a sala e o registro remove o índice.

Estado é somente memória local. Reinício da VM perde todas as salas, o que é coerente
com o MVP, mas deve fazer parte do contrato de reconexão.

## Interfaces e configuração

- TCP/HTTP: `GET /health`, `GET /ws` (upgrade WebSocket), porta `PORT`/8080.
- Browser origin: `ALLOWED_ORIGINS`, lista exata separada por vírgulas.
- App env: `max_connections=128`, `max_rooms=100`, `max_room_members=24`,
  `room_empty_ttl_ms=1000`.
- Dependências fixadas: Cowboy 2.19.0, Cowlib 2.21.0, Ranch 2.3.0 e JSX 3.1.0.
- Não há UDP, TLS, endpoint de mídia, distribuição BEAM ou porta administrativa.

## Avaliação arquitetural

- **Separação control/media plane:** CONFIRMADO para o que existe: somente control plane.
  O media plane deve ser um caminho separado; nunca encaminhar RTP pelo `gen_server` da sala.
- **Isolamento de falhas:** adequado após adicionar supervisor de salas. Uma sala não
  derruba registro nem irmãs.
- **Contratos:** o behaviour de mídia é prematuro mas pequeno. Só deve crescer quando uma
  implementação real definir erros, ownership e backpressure.
- **Concorrência:** criação é serializada e evita duplicar uma sala. Estado de cada sala
  tem um único dono, eliminando check-then-write entre conexões.
- **Backpressure:** há limites na entrada. Não há fila de saída/media; clientes lentos e
  broadcasting ainda precisam de teste quando essas funções existirem.
- **Persistência:** não é necessária para o MVP. Não adicionar banco ou fila externa sem
  requisito de estado durável.

## Recomendações

1. Implementar autenticação/ACL antes de ampliar o protocolo.
2. Colocar TLS na borda e manter Cowboy em loopback/rede privada.
3. Definir versão e IDs de operação antes de adicionar SDP/ICE, para tratar duplicação e ordem.
4. Ao adicionar mídia, usar biblioteca WebRTC consolidada, processos separados por
   transport/peer e limites explícitos; não criar criptografia própria.
5. Adicionar métricas pequenas: conexões, salas, membros, rejeições, mailbox e duração de
   calls. Não logar tokens, SDP completo, candidatos privados ou payloads.

Não se recomenda microserviço, banco, broker ou ETS neste estágio. Os limites atuais e
o isolamento por processo são suficientes para o alvo de 6 usuários e ensaio de 24.
