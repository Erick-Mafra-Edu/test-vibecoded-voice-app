# Hardening plan

## P0 — bloqueia qualquer exposição pública

### 1. Autenticação assinada e ACL por sala

- Derivar identidade do token, nunca de `user` no JSON.
- Verificar issuer, audience, assinatura, expiração e clock skew.
- Autorizar join por `(subject, room)` antes de criar a sala.
- Definir uma sessão ativa por identidade/sala e política atômica de substituição.
- **Aceite:** testes mostram token ausente/inválido/expirado negado, usuário autorizado
  aceito, usuário de outra sala negado e JSON não consegue trocar identidade.

### 2. TLS/WSS obrigatório em produção

- Terminar TLS em proxy conhecido ou no Cowboy; bind interno/loopback.
- Configurar HSTS somente depois de HTTPS estável e redirecionar HTTP.
- **Aceite:** conexão `ws://` pública falha/redireciona; `wss://` usa certificado válido,
  suites modernas e teste automatizado de renovação.

### 3. Admission control além da conexão

- Limite por IP/subject na borda e quota por subject/sala após autenticação.
- Preservar os limites globais como última defesa.
- **Aceite:** um cliente não ocupa todas as 128 conexões; rejeições são métricas e não
  aumentam continuamente processos/mailboxes.

## P1 — antes do primeiro piloto privado

### 4. Protocolo versionado e reconexão

- Adicionar versão explícita e IDs de operação somente quando SDP/ICE for introduzido.
- Definir idempotência, mensagens duplicadas/fora de ordem e fechamento de sessão.
- **Aceite:** testes de duplicação, reorder, reconnect simultâneo e timeout preservam uma
  única identidade ativa sem deixar sala órfã.

### 5. Observabilidade de baixo custo

- Medir contagem de conexões/salas/membros, rate-limit, tempo de call e mailbox máxima.
- Alertar em restart intensity, memória da VM e p99; nunca registrar segredos/payload integral.
- **Aceite:** dashboard local explica saturação de CPU, memória ou mailbox em teste de 24 clientes.

### 6. Gate de supply chain

- Executar scanner de imagem/SBOM em PR/tag, falhar em High/Critical sem exceção com prazo.
- Adicionar environment protegido e assinatura keyless da imagem publicada.
- **Aceite:** tag não publica se testes/scanner falharem; digest, provenance e assinatura são verificáveis.

### 7. Carga e falha repetíveis

- Rodar 30 repetições do benchmark em VPS dedicada de 2 vCPUs.
- Adicionar cenário WebSocket completo: 2/6/12/24 e depois 128 conexões, clientes lentos,
  reconnect e kill de sala/registro.
- **Aceite:** orçamento documentado de p95/p99, CPU, RSS e mailbox sem crescimento após cooldown.

## P2 — somente quando mídia for implementada

### 8. Plano de mídia separado

- Selecionar biblioteca WebRTC mantida; não implementar DTLS/SRTP/ICE manualmente.
- Autorizar publish/subscribe por sala e validar SDP, ICE, SSRC, RTP/RTCP e bitrate.
- Implementar consent freshness, replay protection e proteção contra amplificação UDP.
- **Aceite:** interoperabilidade com dois peers, TURN obrigatório no cenário restrito,
  isolamento entre salas e fuzz local de pacotes malformados.

### 9. Roteamento P2P/SFU baseado em evidência

- Medir RTT de rota, perda, jitter e playout; usar hysteresis/cooldown e make-before-break.
- Garantir deduplicação de áudio e continuidade SSRC/sequence.
- **Aceite:** troca não duplica stream e relatório separa latência do servidor de áudio ponta a ponta.

## Correções já concluídas nesta branch

- Dependências vulneráveis atualizadas e lockfile criado.
- Supervisor dinâmico, limpeza e limites de salas/membros.
- Limites HTTP/WebSocket, timeout, rate-limit e allowlist de `Origin`.
- Release Docker reproduzível por digest, usuário não-root e testes no build.
- GitHub Actions fixadas por SHA; publicação com SBOM/provenance.
- Regressões EUnit/Common Test e benchmark local adicionados.

## Ordem recomendada

Não iniciar mídia antes de concluir P0. Em seguida, executar P1 no plano de controle.
Somente então iniciar P2. Essa ordem evita construir um media plane sobre identidade e
deploy inseguros.
