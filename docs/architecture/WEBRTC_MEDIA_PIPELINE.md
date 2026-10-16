# Pipeline de mídia

`media/` é uma aplicação Elixir na mesma VM OTP do controle Erlang. ExWebRTC
0.17.0 fornece ICE, DTLS, SRTP, RTP e RTCP. O laboratório usa aiortc independente
e envia PCM gerado deterministicamente, codificado como Opus pelo cliente.

No P2P, SDP/candidatos passam pelo WebSocket autorizado e Opus/SRTP cruza
diretamente entre clientes. Na SFU, a sessão de mídia associa sala, identidade,
transporte e publicador. Um pacote RTP descriptografado pelo transporte do
publicador é enviado às sessões assinantes autorizadas; ExWebRTC escreve SSRC,
payload type e extensões apropriados e cifra com a chave SRTP de cada destino.
Não há transcodificação no encaminhador.

Limites implementados na sessão: até 24 transportes e 64 candidatos por
transporte, áudio somente, 120 pacotes ou 64 KiB de payload por segundo no
uplink, payload de até 1500 bytes, filas de destino limitadas. Esses são
limites defensivos de partida, ainda sem profiling em VPS. A sessão monitora
sala e proprietário para liberar recursos.

O cliente aiortc gera frames PCM de 10 ou 20 ms e mede recepção de áudio
decodificado. T12 usa dois tons para transportar IDs lógicos módulo 256 dentro
do Opus de teste; o destinatário contabiliza gaps e descarta marcadores
duplicados/atrasados do playout lógico. Isso não mede latência de áudio ponta
a ponta e não integra um player/navegador de produção. TURN, NAT público,
consent freshness sob diferentes topologias e
compatibilidade com navegadores permanecem sem teste de integração.

Executar: `docker compose -f compose.test.yaml up --build --abort-on-container-exit --exit-code-from test-runner`.
Ver `docs/testing/NETWORK_LAB.md` para topologia e restrições.
