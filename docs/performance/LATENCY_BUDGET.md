# Orçamento de latência

Objetivo experimental: p95 do encaminhamento SFU abaixo de 5 ms em rede
local controlada, seis participantes, servidor limitado a 2 vCPUs/512 MiB.
Isto **não** é resultado medido. Relatar junto p50/p95/p99, número de amostras,
intervalo, CPU, memória, versão da imagem e perfil de netem.

Latência ponta a ponta inclui captura, duração do frame Opus (10 ou 20 ms),
codificação, pacotes/rede, jitter buffer, decodificação e reprodução. O tempo
entre entrada e enfileiramento de RTP na SFU mede somente uma parcela.
RTT também não mede latência unidirecional de áudio.

O gerador aiortc aceita frames de 10/20 ms. T12 usa IDs acústicos módulo 256
em Opus para medir gaps, duplicatas e intervalo entre callbacks do playout
lógico. Na primeira execução aprovada, o maior intervalo observado foi
**576 ms** durante perda/jitter e trocas de rota; na rodada final foram
**477,3 ms** (p95 dos intervalos: **51,6 ms**). Isso não demonstra troca
imperceptível. Ainda falta relacionar o timestamp de origem ao áudio ouvido
em um player, com relógios calibrados e atraso do jitter buffer medido.
