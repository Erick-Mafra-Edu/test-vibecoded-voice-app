# Security audit

> Registro histórico da baseline anterior à integração WebRTC. Trechos abaixo
> como "mídia ausente", "sem autenticação" e "sem ETS" não descrevem a branch
> atual. Evidências e limites atuais: `docs/testing/TEST_RESULTS.md`.

Data da auditoria: 2026-10-16. Escopo: todos os arquivos versionados do BeamVoice,
incluindo código, testes, dependências, Docker, documentação e GitHub Actions.
Modelo de ameaça: cliente remoto não confiável, conexões instáveis e uma VPS de 2 vCPUs.

## Resumo executivo

O repositório implementa apenas um MVP de sinalização. Não implementa áudio, WebRTC,
ICE/STUN/TURN, SDP, RTP/RTCP, Opus, DTLS-SRTP nem SFU. Também não implementa
autenticação ou ACL de salas. Portanto, **não deve ser exposto à Internet**.

Foram confirmados dois bloqueios de produção ainda abertos: ausência de identidade/ACL
e ausência de TLS. Foram corrigidos limites de recursos, validação de `Origin`,
supervisão/limpeza de salas, dependências HTTP vulneráveis, build não reproduzível e
endurecimento de CI/imagem. Não há uso de ETS, `binary_to_term/1` ou criação de atoms a
partir da entrada externa no código atual.

## Achados priorizados

### S-01 — Identidade falsificável e salas sem autorização

- **Classificação:** CONFIRMADO · Crítico · exploração trivial · pendência bloqueante.
- **Evidência:** o cliente escolhe `room` e `user` no JSON e o handler os aceita em
  `src/beamvoice_ws_handler.erl:33-47`. O próprio README documenta a ausência de
  autenticação em `README.md:25-30`.
- **Cenário:** qualquer cliente conecta, escolhe o nome de outro usuário, ocupa seu
  identificador e entra em qualquer sala cujo nome conheça ou adivinhe.
- **Impacto:** impersonação, negação de entrada ao usuário real e ausência completa de
  isolamento entre salas.
- **Correção necessária:** validar um token assinado no upgrade, derivar `user` apenas
  das claims e consultar uma ACL de sala antes de criá-la ou ingressar nela. Definir
  expiração, revogação e semântica de reconexão antes de alterar o contrato público.
- **Status:** PENDENTE. Não foi criado um “token compartilhado”, pois ele não forneceria
  isolamento entre usuários e criaria uma garantia falsa.

### S-02 — Transporte público sem TLS/WSS

- **Classificação:** CONFIRMADO · Alto · exploração fácil com acesso à rede · pendência bloqueante.
- **Evidência:** o listener usa `cowboy:start_clear/3` em
  `src/beamvoice_http.erl:8-16`; não há certificados nem proxy TLS no repositório.
- **Cenário:** em uma rede não confiável, um intermediário lê ou altera sinalização e
  identificadores. Quando SDP/ICE existir, a mesma falha exporá metadados ainda mais sensíveis.
- **Impacto:** perda de confidencialidade e integridade da sinalização.
- **Correção necessária:** terminar TLS 1.2+ em proxy confiável ou usar
  `cowboy:start_tls/3`, redirecionar HTTP para HTTPS e aceitar apenas WSS em produção.
- **Status:** PENDENTE. O bind recomendado continua restrito a `127.0.0.1`.

### S-03 — Dependências HTTP com vulnerabilidades conhecidas

- **Classificação:** CONFIRMADO · Alto · exploração média, remota e sem autenticação · CORRIGIDO.
- **Evidência:** a linha de base fixava Cowboy 2.12.0/Cowlib 2.13.0. Essas versões são
  afetadas por exaustão de memória em HTTP/1.1 e HTTP/2 (CVE-2026-65624 e
  CVE-2026-59248). Fontes: [GHSA-v9x8-262p-f2g5](https://github.com/advisories/GHSA-v9x8-262p-f2g5)
  e [GHSA-f37p-pc7r-rghm](https://github.com/advisories/GHSA-f37p-pc7r-rghm).
- **Cenário:** um cliente envia cabeçalhos repetidos ou inteiros HPACK especialmente
  formados e força alocação excessiva antes de qualquer autenticação.
- **Impacto:** CPU/heap elevados e possível encerramento da VM por falta de memória.
- **Correção:** `rebar.config:2` agora usa Cowboy 2.19.0; `rebar.lock` fixa Cowlib
  2.21.0 e Ranch 2.3.0 com hashes. Limites de cabeçalho foram adicionados em
  `src/beamvoice_http.erl:12-15`.
- **Status:** CORRIGIDO. Uma varredura de CVEs da imagem base não foi executada; ver S-10.

### S-04 — Recursos e processos podiam crescer sem limite

- **Classificação:** CONFIRMADO · Alto · exploração fácil, remota e sem autenticação · CORRIGIDO parcialmente.
- **Evidência:** antes da correção, cada ID criava uma sala permanente, não havia limite
  de salas/participantes/conexões e cada WebSocket podia enviar mensagens sem limite.
- **Cenário:** um cliente cria IDs de sala únicos ou abre várias conexões e envia
  `members` continuamente.
- **Impacto:** crescimento de processos, mapas, monitores, mailboxes e CPU até indisponibilidade.
- **Correção:** 128 conexões globais (`src/beamvoice_http.erl:9-11`), 4 KiB por frame,
  idle timeout e fluxo ativo limitado (`src/beamvoice_ws_handler.erl:10-11`), 20
  mensagens/s por conexão (`src/beamvoice_ws_handler.erl:66-72`), 100 salas e 24
  membros por sala (`src/beamvoice.app.src:7-10`). Salas vazias encerram em
  `src/beamvoice_room.erl:32-50`.
- **Status:** CORRIGIDO para carga acidental e abuso simples. Sem autenticação ou limite
  por IP, um atacante ainda pode ocupar todas as 128 conexões; isso permanece Alto.

### S-05 — Cross-Site WebSocket Hijacking por ausência de política de Origin

- **Classificação:** CONFIRMADO · Alto no serviço local · exploração fácil via navegador · CORRIGIDO.
- **Evidência:** o handler original aceitava qualquer upgrade. A validação atual está em
  `src/beamvoice_ws_handler.erl:5-16,74-82` e o teste de handshake em
  `test/beamvoice_SUITE.erl`.
- **Cenário:** uma página maliciosa aberta no navegador da vítima conecta ao serviço em
  `localhost:8080` e opera o protocolo em nome do navegador.
- **Impacto:** uso indevido do serviço local e preparação para sequestro de sessão caso
  cookies sejam adicionados futuramente.
- **Correção:** allowlist exata por `ALLOWED_ORIGINS`; origins de navegador não
  permitidas recebem HTTP 403. Clientes não-browser sem `Origin` continuam aceitos.
- **Status:** CORRIGIDO e coberto por Common Test.

### S-06 — Salas não supervisionadas derrubavam o registro

- **Classificação:** CONFIRMADO · Alto operacional · exploração média, exige provocar falha de sala · CORRIGIDO.
- **Evidência:** o registro chamava `beamvoice_room:start_link/1`, ligando todas as salas
  ao próprio `gen_server`; não havia supervisor de salas. Uma saída anormal propagava
  pelo link.
- **Cenário:** uma falha de uma sala encerra o registro e todas as demais salas ligadas.
- **Impacto:** falha ampliada, perda do índice e desconexões em massa.
- **Correção:** `beamvoice_room_sup` cria filhos temporários isolados
  (`src/beamvoice_room_sup.erl:7-16`); o registro reconstrói seu índice após reinício
  (`src/beamvoice_room_registry.erl:10-14`).
- **Status:** CORRIGIDO; reinício e preservação da sala são testados em Common Test.

### S-07 — Payloads inesperados e flooding não eram encerrados

- **Classificação:** CONFIRMADO · Médio · exploração fácil e remota · CORRIGIDO.
- **Evidência:** padrões de mapas aceitavam campos extras e respostas de erro mantinham
  a conexão indefinidamente. Agora `map_size/1` exige o contrato exato em
  `src/beamvoice_ws_handler.erl:33-58`.
- **Cenário:** clientes enviam extensões ambíguas, frames grandes ou rajadas de JSON para
  consumir decodificação e mailbox.
- **Impacto:** inconsistência de protocolo e consumo previsivelmente maior de CPU/memória.
- **Correção:** schema mínimo exato, frame máximo, fechamento 1009 para excesso e 1008
  para rate limit. JSON malformado fica limitado a 4 KiB.
- **Status:** CORRIGIDO com EUnit. O limite é por conexão, não por IP.

### S-08 — Supply chain e publicação mutáveis

- **Classificação:** CONFIRMADO · Alto · exploração difícil, exige comprometimento upstream ou permissão de release · CORRIGIDO parcialmente.
- **Evidência:** a imagem baixava `rebar3` de uma URL sem checksum, não havia lockfile,
  a base e as Actions usavam tags mutáveis, e o workflow de tag podia publicar sem que
  o workflow CI fosse acionado.
- **Cenário:** alteração de tag/artefato upstream muda o build ou executa código no runner;
  uma tag do projeto publica imagem sem testes de aplicação.
- **Impacto:** imagem não reproduzível ou comprometida no GHCR.
- **Correção:** base por digest e rebar3 já presente na imagem (`Dockerfile:1-8`),
  lockfile com hashes, Actions por SHA, testes dentro do build e atestações SBOM/provenance
  em `.github/workflows/publish.yml:12-26`.
- **Status:** CORRIGIDO para mutabilidade conhecida. Assinatura keyless e aprovação de
  environment para release permanecem pendentes.

### S-09 — Funcionalidades de mídia citadas não existem

- **Classificação:** CONFIRMADO · Crítico se divulgado como VoIP seguro · exploração não aplicável · documentado.
- **Evidência:** `src/beamvoice_media_adapter.erl` contém somente três callbacks; não há
  implementação de SDP, ICE, RTP, RTCP, Opus, DTLS, SRTP, TURN ou SFU.
- **Cenário:** operar o MVP como serviço de voz presumindo que mídia esteja protegida.
- **Impacto:** não existe chamada de áudio nem qualquer garantia de segurança de mídia.
- **Correção necessária:** escolher biblioteca WebRTC consolidada e testar autorização,
  DTLS-SRTP, consent freshness, replay, SSRC, bitrate e isolamento antes de produção.
- **Status:** PENDENTE por design; README e roadmap agora são explícitos.

### S-10 — Cobertura de vulnerabilidades do sistema operacional

- **Classificação:** NÃO VERIFICADO · risco potencial de supply chain · facilidade desconhecida.
- **Evidência:** a imagem foi construída por digest e mede 59.671.689 bytes, mas não havia
  Trivy/Grype/Docker Scout offline com base de CVEs confiável no ambiente.
- **Impacto:** uma CVE no Alpine/ERTS pode permanecer invisível.
- **Correção necessária:** gerar SBOM e bloquear release em CVEs High/Critical com uma
  exceção versionada e prazo. Atualizar deliberadamente o digest base.
- **Status:** PENDENTE.

## Verificações negativas

- **CONFIRMADO:** nenhuma chamada a `binary_to_term`, `list_to_atom` ou
  `binary_to_atom`; não há risco de atom table vindo do protocolo atual.
- **CONFIRMADO:** não existe ETS; portanto, não há tabela ETS com crescimento oculto.
- **CONFIRMADO:** não há segredos versionados nos arquivos inspecionados; o workflow usa
  somente `GITHUB_TOKEN` com `contents: read` e `packages: write` no job de publicação.
- **POTENCIAL:** respostas `members` copiam até 24 IDs e são serializadas no processo da
  conexão. O limite torna o custo pequeno, mas clientes lentos não foram ensaiados.
- **NÃO VERIFICADO:** segurança real de WebRTC/mídia, pois esses componentes não existem.

## Decisão de produção

**NO-GO para exposição pública.** S-01 e S-02 são bloqueios. O serviço pode ser usado
somente em desenvolvimento local/rede confiável, com bind loopback e os limites descritos.

## Atualização da branch WebRTC — 2026-10-16

- **CONFIRMADO · corrigido na branch:** credenciais opacas por usuário e ACL de
  sala vinculam identidade ao WebSocket; SDP/ICE e transportes SFU são
  autorizados pela associação à sala. T01/T02/T10 e testes EUnit/ExUnit
  executaram esses caminhos. A baseline acima permanece como evidência histórica.
- **CONFIRMADO · pendente, severidade média:** `mix deps.get` sinaliza
  `cowlib 2.21.0` com EEF-CVE-2026-43966 (response splitting em
  `cow_http_struct_hd:escape_string/2`). A presença da versão é comprovada;
  a exploração por uma entrada específica do BeamVoice **não foi verificada**.
  Acompanhar versão corrigida, atualizar lockfiles e repetir build/testes.
- **POTENCIAL · alto para Internet pública:** TURN/NAT, navegador, renovação de
  TLS, rotação/revogação de credenciais e comportamento sob indisponibilidade
  prolongada não foram validados. A fixture do Compose contém tokens apenas de
  laboratório, nunca de produção.
- **NÃO VERIFICADO:** scanner confiável de CVEs na imagem final, execução dos
  workflows GitHub e soak/malha integralmente SFU. Não declarar deploy público
  seguro antes desses gates.
