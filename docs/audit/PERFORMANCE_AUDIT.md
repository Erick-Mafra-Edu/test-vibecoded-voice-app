# Performance audit

Data: 2026-10-16. O resultado mede somente o plano de controle Erlang; BeamVoice não
possui plano de mídia. Nenhum número abaixo representa latência de áudio ponta a ponta.

## Metodologia

- Host Windows com Docker Desktop; imagem `erlang:27-alpine`, OTP 27/ERTS 15.2.7.9.
- Contêiner restrito a 2 vCPUs e 512 MiB.
- 2, 6, 12 e 24 processos clientes ingressam em uma sala e cada um executa 100 chamadas
  síncronas `beamvoice_room:members/1`.
- Cronometragem monotônica em microssegundos; percentis calculados sobre 200, 600, 1.200
  e 2.400 operações.
- Mailbox e memória do processo da sala são lidos ao final da rodada.
- Harness reproduzível: `bench/room_bench.escript`.

Comando:

```sh
rebar3 compile
docker run --rm --cpus=2 --memory=512m -v "$PWD:/app" -w /app \
  erlang:27-alpine escript bench/room_bench.escript
```

## Resultados

### Linha de base, antes das correções

| Clientes | Operações | p50 µs | p95 µs | p99 µs | máximo µs | mailbox | memória da sala |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 | 200 | 5 | 33 | 40 | 50 | 0 | 26.568 B |
| 6 | 600 | 7 | 39 | 132 | 311 | 0 | 11.904 B |
| 12 | 1.200 | 16 | 63 | 157 | 185 | 0 | 18.768 B |
| 24 | 2.400 | 27 | 82 | 114 | 182 | 0 | 29.480 B |

### Após as correções

| Clientes | Operações | p50 µs | p95 µs | p99 µs | máximo µs | mailbox | memória da sala |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 2 | 200 | 2 | 12 | 33 | 82 | 0 | 16.832 B |
| 6 | 600 | 6 | 37 | 54 | 131 | 0 | 19.304 B |
| 12 | 1.200 | 16 | 39 | 84 | 90 | 0 | 11.520 B |
| 24 | 2.400 | 31 | 134 | 218 | 251 | 0 | 28.296 B |

## Interpretação

- **CONFIRMADO:** uma sala é um ponto de serialização. A p50 cresceu com a concorrência;
  em 24 clientes, a rodada pós-correção teve p99 de 218 µs.
- **CONFIRMADO:** a mailbox estava vazia no instante da amostra em todas as rodadas. Isso
  não prova ausência de picos durante a execução.
- **CONFIRMADO:** o processo da sala ficou abaixo de 30 KiB nas amostras, mas esse valor
  exclui processos WebSocket, Ranch/Cowboy, binaries compartilhados e memória da VM.
- **NÃO VERIFICADO:** a diferença entre antes/depois não pode ser atribuída ao diff. Foi
  feita uma única rodada de cada versão sob Docker Desktop, sem warm-up, afinidade de CPU
  ou intervalo de confiança. Os resultados são smoke benchmarks, não uma regressão estatística.
- **POTENCIAL:** `members/1` cria uma lista com `maps:keys/1` e o handler a serializa a
  cada pedido. Com o limite de 24 membros, o custo é aceitável; só deve ser redesenhado
  se métricas reais mostrarem pressão.

## Gargalos e previsibilidade

1. O `gen_server` de cada sala serializa join/leave/members. Isso isola salas e é adequado
   para 24 membros, mas flooding de `members` disputa o mesmo mailbox.
2. O registro serializa apenas criação/listagem e não participa do caminho `members` após
   o ingresso. Ele não é gargalo de mídia porque mídia não existe.
3. Calls agora têm timeout de 2 s (`beamvoice_room.erl` e
   `beamvoice_room_registry.erl`), limitando o tempo de retenção de um handler congestionado.
4. Frames são limitados a 4 KiB, e `active_n=20` reduz a alimentação de mensagens ao
   processo WebSocket. Há limite global de 128 conexões e 20 mensagens/s por conexão.

## Limitações e próximos benchmarks

- **NÃO VERIFICADO:** CPU por processo, reduções/segundo, frequência de GC, pico de
  mailbox, pressão de binaries e latência do WebSocket completo. Instrumentar com
  `telemetry`/VM metrics só quando houver coleta externa definida.
- **NÃO VERIFICADO:** clientes lentos, reconexão contínua, 128 conexões simultâneas e
  tráfego distribuído entre muitas salas.
- **NÃO APLICÁVEL:** encaminhamento RTP, jitter, perda, bitrate, troca P2P/SFU e áudio
  ponta a ponta. Não existem pacotes de mídia no repositório.
- Para um gate repetível, executar ao menos 30 rodadas, descartar warm-up e comparar
  mediana e intervalo p95/p99 em uma VPS dedicada de 2 vCPUs. Não executar contra serviço público.
