# Resultados de teste — 2026-10-16

Resultados locais em Docker Compose privado, sem tráfego para servidores de
terceiros. **PASSOU** significa que a asserção foi executada, não que o sistema
esteja pronto para produção. A branch é `feature/hybrid-webrtc-routing`.

## Compilação e testes de código

O build da imagem final concluiu `rebar3 eunit` (**25/25**), `rebar3 ct`
(**3/3**) e `mix test` (**2/2**, incluindo transporte real ExWebRTC). Baseline
anterior à implementação: 16 EUnit e 2 CT. `docker compose config --quiet`,
`git diff --check` e `python -m py_compile lab/*.py` passaram localmente.
Os testes de unidade cobrem ACL, limites de salas e WebSocket, métricas, política,
transições/rollback e validação de SDP. Não há cobertura percentual instrumentada.

## Cenários WebRTC reais

| ID | Resultado | Evidência objetiva |
|---|---|---|
| T01 | PASSOU | ICE/DTLS P2P, Opus não silencioso, rota P2P; zero frames SFU para o fluxo ativo. |
| T02 | PASSOU | UDP direto bloqueado nos dois sentidos; rota SFU e PCM recebido. |
| T03 | PASSOU | Perda/jitter seletivos no direto; ativação SFU e mídia recebida. |
| T04 | PASSOU | SFU degradada, P2P conectado e ativo; zero frames SFU encaminhados ao fluxo. |
| T05 | PASSOU | Após SFU, retorno a P2P com histerese e recepção. |
| T06 | PASSOU | Dois ciclos completos e três oscilações rápidas; cinco ativações, zero trocas extras. |
| T07 | PASSOU | Seis peers, 30 fluxos dirigidos P2P, uma rota SFU seletiva; receptor mantém outro fluxo P2P. |
| T08 | PASSOU | Contêiner de peer encerrado e reiniciado; `peer_left` recebido e mídia entre os demais prossegue. |
| T09 | PASSOU | Sessão de mídia encerrada por fault hook local; P2P preservado, nova sessão SFU negociada. |
| T10 | PASSOU | Entrada sem autenticação rejeitada; 90 JSONs inválidos geram fechamento 1008. |
| T11 | PASSOU | 2/6/12/24 peers, frames 10/20 ms: oito casos P2P em anel, com amostras de recursos. |
| T12 | PASSOU, com lacunas | P2P→SFU→P2P e rollback durante Opus contínuo; frames retornam após cada troca. |

Comando único exigido, `docker compose -f compose.test.yaml up --build
--abort-on-container-exit --exit-code-from test-runner`, terminou com **código
0** em T01–T05, T07 e T10. T08 rodou separadamente com `docker compose run
--rm -e SCENARIOS=T08 test-runner` (código 0), pois o desligamento intencional
de um peer faria o `up --abort-on-container-exit` abortar antes da asserção.
T06/T09/T12 rodaram juntos com `docker compose run --rm -e
SCENARIOS=T06,T09,T12 test-runner` (código 0). T11 rodou com
`SCENARIOS=T11` (código 0). Evidências locais brutas:

- `lab/results/run-1792178280540636895.json`: T01–T05, T07, T10;
- `lab/results/run-1792178341172873930.json`: T08;
- `lab/results/run-1792178348306708379.json`: T06, T09, T12;
- `lab/results/run-1792178081621713216.json`: T11.

Esses artefatos são gerados localmente e ignorados pelo Git; os comandos acima
os reproduzem. Não contêm tokens nem SDP completos. Valores de benchmark:
`docs/performance/BENCHMARK_RESULTS.md`.

T12 tocou logicamente **1.375 frames** com IDs acústicos Opus módulo 256. Houve
**433 IDs ausentes**, 9 duplicatas e 50 frames atrasados descartados antes do
playout lógico; após esse filtro, zero duplicatas/ordens regressivas tocadas.
Intervalos de callback do playout: p50 **20,0 ms**, p95 **51,6 ms**, p99
**228,9 ms**, máximo **477,3 ms**. As ativações foram P2P→SFU→P2P, com um
rollback. Preparação→ativação mediu 92,6 ms para SFU e 15,2 ms no retorno,
mas **não** equivale ao tempo total de degradação ou de silêncio. A marca é
módulo 256 e seus IDs ausentes não são uma estimativa isolada de perda de rede;
incluem estabelecimento, troca e descartes do cliente. Não há teste de alto-
falante/navegador ou latência acústica ponta a ponta.

## Critérios finais de aceite

| Requisito | Estado | Limite da evidência |
|---|---|---|
| 1. P2P WebRTC real | PASSOU | T01, aiortc ICE/DTLS-SRTP/Opus. |
| 2. Dois peers via SFU | PASSOU | T02, mídia decodificada e encaminhada. |
| 3. Rota ativa identificada | PASSOU | Eventos e snapshot T01–T07. |
| 4. Degradação detectada | PASSOU | T03 sob netem seletivo. |
| 5. Troca efetiva coordenada | PASSOU | T03/T05/T12. |
| 6. Mídia após a troca | PASSOU | T12. |
| 7. Sem duplicação contínua | PASSOU no laboratório | Filtro de playout lógico T12; cliente de produção não existe. |
| 8. Seis peers na sala | PASSOU | T07 com malha P2P e um fluxo SFU; não prova malha SFU completa. |
| 9. Falha de peer isolada | PASSOU | T08. |
| 10. Testes Docker Compose | PASSOU | Comando único e T08 separado. |
| 11. CI valida cenários básicos | NÃO VERIFICADO | Workflows configurados, não executados no GitHub. |
| 12. Latência/perda/estabilidade documentadas | PASSOU parcialmente | Dados locais T11/T12; sem E2E ou p95 de encaminhamento SFU. |

## Falhas observadas e limites

- Uma tentativa anterior de T07 negociou 36 transportes SFU além da malha P2P;
  conexões parciais falharam em 45 s. O T07 final usa uma única rota SFU
  seletiva, coerente com o aceite híbrido. A capacidade de seis peers **todos
  em SFU** continua **NÃO VERIFICADA**, não aprovada.
- Uma tentativa T11 exigia incorretamente no benchmark em anel a segunda rota
  do T07; T11-6-10/20 falhou por essa condição impossível. Após separar os
  cenários, os oito casos T11 passaram. Os artefatos da falha foram mantidos.
- O workflow GitHub, TLS com certificados reais, TURN/NAT, navegador, scanner
  de imagem, soak de horas, p95 de encaminhamento SFU e áudio ponta a ponta
  permanecem **NÃO VERIFICADOS**.
- O Compose encerrou o servidor com saída 137 após o runner terminar com 0;
  isso ocorreu durante o teardown automático, não durante uma asserção. A
  duração/qualidade do shutdown gracioso ainda não foi medida.
