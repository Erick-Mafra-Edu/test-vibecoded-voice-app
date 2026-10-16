# Supervisão OTP

`beamvoice_sup` supervisiona o registro de salas, o supervisor dinâmico de
salas, as métricas e o listener Cowboy. Cada sala é um `gen_server` com
monitoramento de WebSockets; salas vazias encerram após período de graça.
O aplicativo `beamvoice_media` tem Registry e DynamicSupervisor, com uma
sessão temporária por participante que precisou de mídia SFU. Cada sessão
possui seus PeerConnections, monitora WebSocket e sala, e limpa os transportes
ao terminar. Coordenadores de rota são ligados ao WebSocket proprietário.

O plano de controle pode serializar mensagens por WebSocket, mas o plano de
mídia não passa por um processo global Erlang: cada participante tem sua
própria sessão. Registry e métricas são globais apenas para lookup/contagem.
O fanout copia referências a binaries de RTP entre processos; carga de 24
peers ainda deve medir pressão de mailbox e garbage collection.

Falha do processo de mídia notifica o WebSocket com `media_failed`; os pares
P2P continuam independentes. Reinício e renegociação SFU automática ainda
precisam de teste de falha injetada. O fechamento da sala avisa o cliente e
termina sua sessão de mídia via monitor. O isolamento depende também da
autorização do protocolo WebSocket, descrita no relatório de segurança.
