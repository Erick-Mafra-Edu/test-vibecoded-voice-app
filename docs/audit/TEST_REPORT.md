# Test report

Data: 2026-10-16. Execução exclusivamente local, em contêiner Docker com 2 vCPUs e
512 MiB. Nenhum servidor público ou terceiro recebeu carga.

## Ambiente

- Host: Windows/Docker Desktop.
- Erlang: OTP 27, ERTS 15.2.7.9.
- rebar3: 3.26.0.
- Dependências finais: Cowboy 2.19.0, Cowlib 2.21.0, Ranch 2.3.0, JSX 3.1.0.
- Branch: `audit/security-performance-hardening`.

## Linha de base

| Comando | Resultado |
|---|---|
| `rebar3 compile` no contêiner | passou |
| `rebar3 eunit` | 6/6 passaram |
| `rebar3 ct` | passou com 0 casos — sem cobertura efetiva |
| `docker build -t beamvoice:audit-baseline .` | falhou: “No releases have been specified” |

## Resultado final

| Verificação | Resultado |
|---|---|
| compilação com `warnings_as_errors` | passou |
| EUnit | 16/16 passaram |
| Common Test | 2/2 passaram |
| release Relx | montada sem chamadas runtime ausentes |
| build Docker | passou; testes rodam dentro do build |
| execução read-only/non-root | passou; usuário `app`, UID 100 |
| limites do contêiner | confirmados: 2 CPUs, 512 MiB |
| `GET /health` da imagem final | HTTP 200, `{"status":"ok"}` |
| `git diff --check` | passou; apenas avisos de conversão LF/CRLF do Git local |

## Cobertura efetiva adicionada

- join/leave, join duplicado, participante inválido e desconexão abrupta;
- encerramento de sala vazia, reconexão durante a janela de coleta e limite de participantes;
- 24 joins concorrentes;
- limite e coleta de salas;
- reconstrução do registro e preservação da sala após reinício;
- JSON malformado, campos inesperados, payload acima de 4 KiB e flooding controlado;
- handshake WebSocket com `Origin` permitido e negado;
- restart do processo registrado sob o supervisor.

Os testes adversariais usam no máximo 24 processos/2.400 operações e são locais.

## Benchmark

O benchmark reproduzível está em `bench/room_bench.escript`. Na rodada final, com 24
clientes e 2.400 calls de controle, foram observados p50 31 µs, p95 134 µs, p99 218 µs,
máximo 251 µs, mailbox final 0 e 28.296 bytes no processo da sala. Metodologia e todos
os resultados estão em `PERFORMANCE_AUDIT.md`.

## Cobertura e limitações

- **NÃO VERIFICADO:** porcentagem de cobertura de linhas/ramos; `cover` não foi executado.
- **NÃO VERIFICADO:** fuzzing e PropEr. A dependência PropEr não era usada e foi removida;
  os invariantes atuais têm testes determinísticos menores.
- **NÃO VERIFICADO:** soak test, 128 sockets, cliente lento, partição de rede, OOM e CPU throttling prolongado.
- **NÃO VERIFICADO:** execução dos workflows no GitHub; Actions foram revisadas estaticamente.
- **NÃO VERIFICADO:** scanner de CVEs do sistema operacional da imagem.
- **NÃO APLICÁVEL:** testes RTP/RTCP, jitter, áudio, ICE/TURN, SRTP, SFU e troca de rota,
  porque esses componentes não existem.

## Comandos de reprodução

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
escript bench/room_bench.escript
docker build -t beamvoice:audit .
docker run --rm --cpus=2 --memory=512m --read-only --tmpfs /tmp \
  --cap-drop=ALL --security-opt no-new-privileges \
  -p 127.0.0.1:8080:8080 beamvoice:audit
```
