# Roteamento híbrido

Cada fluxo dirigido `publicador → destinatário` tem um `beamvoice_route_coordinator`
(`gen_statem`). O WebSocket pertence a uma identidade autenticada, verifica
associação à sala e recebe amostras por transporte. ICE escolhe candidatos dentro
de cada `RTCPeerConnection`; a aplicação decide entre os dois transportes.

O coordenador usa janelas de métricas recentes, exige ICE e DTLS conectados e
prefere P2P saudável. Uma amostra sem RTT medido usa `null`; RTT não é tratado
como latência unidirecional. Perda e jitter sustentados, cooldown e timeout
governam as transições. O fluxo envia `route_prepare(epoch,route)`, aguarda
`route_ready` após recepção real de mídia, envia `route_commit`, recebe
`route_ack` e então confirma `route_active`. Timeout gera rollback. O cliente
seleciona apenas uma rota para playout em cada instante. RTP tem SSRC e sequência
distintos por transporte. O cliente do laboratório T12 usa uma marca acústica
de frame e descarta IDs duplicados/atrasados no playout lógico. Clientes reais
ainda precisam de estratégia equivalente e validação audível.

A SFU mantém uma conexão WebRTC por publicação/assinatura e só encaminha após
preparar a rota SFU. Um transporte SFU conectado com zero pacotes é elegível
apenas para a **preparação**; a confirmação exige `route_ready` do cliente
depois de receber mídia. Se P2P estiver saudável, sua preferência evita o
**encaminhamento SFU ao destinatário**, mas o uplink do publicador para a SFU
pode continuar transmitindo para permitir fallback. O servidor ainda não
coordena publicação sob demanda; ver `docs/client/CLIENT_CONTRACT.md`. Não há
estimativa de qualidade da rota futura antes de
ativá-la; a política atual prioriza disponibilidade e P2P.

Configuração de laboratório: `application:set_env(beamvoice, route_options, Map)`
antes de iniciar as sessões. Os padrões de `src/beamvoice_route_coordinator.erl`
incluem janela fresca 3 s, degradação sustentada 3 s e cooldown 3 s.
Esses tempos são política inicial, não valores calibrados por áudio ouvido.
O contrato de mensagens e as responsabilidades de reprodução no cliente estão
em `docs/client/CLIENT_CONTRACT.md`.
