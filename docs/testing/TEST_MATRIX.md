# Matriz de cenários

Resultado executado: ver `TEST_RESULTS.md` e artefato local
`lab/results/results.json`. A presença de código não implica aprovação.

| ID | Aceite primário | Evidência exigida |
|---|---|---|
| T01 | P2P saudável | ICE/DTLS conectados, Opus decodificado, rota P2P, SFU sem encaminhamento |
| T02 | P2P bloqueado | `tc` seletivo, rota SFU, mídia recebida |
| T03 | P2P degradado | perda/jitter seletivos, preparo/commit SFU, continuidade |
| T04 | SFU degradada | P2P ativo, mídia sem SFU no fluxo |
| T05 | Recuperação P2P | cooldown/histerese, retorno após mídia |
| T06 | Oscilação | número de trocas, ausência de flapping |
| T07 | Seis peers | todos publicam/recebem, rotas por destino, recursos |
| T08 | Falha de peer | presença atualizada, demais continuam |
| T09 | Falha SFU | P2P preservado, supervisão e renegociação |
| T10 | Entrada adversarial | autorização, payload, flood, fila limitada |
| T11 | 2/6/12/24 peers | CPU, memória, filas, perdas, jitter, frames 10/20 ms |
| T12 | Troca com mídia contínua | IDs lógicos, perdas, duplicatas, gap e rollback |

T11 usa anel para 2/6/12/24 clientes; T07 testa a malha P2P de seis
com uma rota SFU seletiva, separadamente. T06 usa dois ciclos
completos e três oscilações curtas. T09 injeta uma falha na sessão de mídia
autorizada sob `BEAMVOICE_LAB_FAULTS=true` no Compose privado. T12 codifica
IDs lógicos módulo 256 em dois tons Opus e filtra duplicatas/frames atrasados
antes do playout lógico. Esse marcador é de teste, não uma estratégia de
sincronização para clientes de produção. P2P e SFU exigem DTLS-SRTP.
