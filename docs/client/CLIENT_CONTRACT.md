# Contrato e arquitetura esperada do cliente BeamVoice

Este documento descreve o **servidor atual** e as decisões para construir um
cliente interoperável. O cliente automatizado em `lab/worker.py` comprova o
transporte, mas não é um produto de áudio para usuários. Termos:

- **Obrigatório:** exigido pelo protocolo implementado.
- **Recomendado:** decisão de arquitetura do novo cliente, ainda não validada
  em navegador ou aplicativo nativo.
- **Lacuna:** depende de implementação ou validação adicional; não presumir que
  já funciona em produção.

## Responsabilidades e topologia

O cliente captura **uma** fonte de microfone, negocia WebRTC/Opus, recebe áudio
dos demais participantes e mantém o WebSocket apenas para controle. O servidor
autentica, mantém a sala, retransmite SDP/ICE P2P, termina os transportes
DTLS-SRTP da SFU e escolhe a rota **por publicador e destinatário**. ICE escolhe
candidatos *dentro* de cada conexão; não escolhe entre P2P e SFU.

| Componente recomendado | Estado que possui | Regra principal |
|---|---|---|
| Sinalização | WSS, identidade, sala, presença | Autenticar antes de entrar; não transportar áudio pelo WebSocket. |
| Transportes WebRTC | `RTCPeerConnection` e tracks | Uma conexão P2P por par; um uplink SFU próprio e um downlink SFU por publicador necessário. |
| Rotas | época, rota ativa e pendente por publicador | Aplicar somente eventos do servidor para aquele fluxo; ignorar épocas antigas. |
| Reprodução | uma saída lógica por publicador | Apenas **uma** das tracks P2P/SFU audível em cada instante. |
| Telemetria | amostras por transporte recebido | Enviar métricas observadas, com unidades corretas e sem inventar RTT. |

No P2P, uma conexão por par pode usar áudio `sendrecv`. Na SFU, o cliente cria
um transporte `sendonly` para publicar o próprio áudio e, quando necessário,
um `recvonly` **separado por publicador remoto**. O servidor atual aceita apenas
**um m-line de áudio por oferta SFU** e **um transporte por publicador em cada
sessão**. Use `transport = publisher` como identificador estável nessa sessão,
como faz o laboratório. Não misture tracks P2P e SFU na mesma conexão.

Compartilhar a captura não implica encoder único: vários uplinks P2P podem
consumir CPU. Comece com até seis pessoas e meça CPU/bateria no dispositivo.
Opus é o codec testado; 10/20 ms são parâmetros de experimento do laboratório,
não garantia configurável em todos os clientes WebRTC. No navegador, deixe o
jitter buffer e DTLS-SRTP para a implementação WebRTC da plataforma. **Não
habilite DTX como otimização inicial sem revisar a política do servidor:** ela
exige pelo menos cinco pacotes por janela para declarar um caminho saudável;
silêncio sem pacotes pode parecer falha de rede.

**Dependência do fallback atual:** o destinatário só obtém rota SFU quando já
possui um downlink SFU conectado e reportado; o publicador precisa ter uplink
SFU ativo. O servidor **não** envia uma solicitação de publicação ao publicador.
Para o primeiro cliente, mantenha o próprio uplink SFU e crie downlinks
seletivamente — antecipadamente para contatos prioritários ou ao detectar
degradação P2P local — antes de esperar `route_prepare`. Não abra 30 downlinks
SFU por padrão: o ensaio deles junto da malha P2P falhou e não foi aprovado.
Esse desenho mantém o uplink de áudio publicador→SFU mesmo quando P2P é a rota
audível; somente o encaminhamento SFU→destinatário é desligado. **Lacuna
arquitetural:** cumprir literalmente “nenhuma mídia atravessa o servidor com
P2P saudável” e ainda ter fallback automático requer novo contrato de demanda
de publicação ao publicador, confirmação de uplink pronto e novos testes.

## Sessão WebSocket

1. Abrir `wss://<servidor>/ws` com certificado válido. O `Origin` do navegador
   deve estar na allowlist configurada no servidor. `ws://` existe somente no
   laboratório isolado com `BEAMVOICE_ALLOW_INSECURE=true`.
2. Enviar `{"type":"auth","token":"<credencial opaca>"}` em até **5 s** e
   aguardar `{"type":"authenticated","user":"alice"}`. O servidor define o
   usuário; nunca usar um ID enviado pelo cliente como identidade. O token
   provisionado tem 32–256 bytes; a sala tem até 64 bytes e deve estar na ACL.
3. Enviar `{"type":"join","room":"friends"}` e aguardar `joined`, que contém
   `user` e `members`. Depois, aplicar `peer_joined`/`peer_left` para presença.
4. Após entrar, `{"type":"members"}` retorna a lista atual. Se a sala estiver
   ociosa, usá-lo como keepalive a cada ~30 s; o WebSocket tem timeout ocioso
   de 60 s e a API WebSocket do navegador não expõe ping de protocolo.

Após `joined`, `{"type":"chat","content":"olá"}` envia texto à sala. O
servidor aceita de 1 a 2.000 bytes UTF-8, define o autor pela sessão
autenticada e entrega `{"type":"chat","from":"alice","content":"olá"}`
aos participantes, incluindo o remetente. O chat é efêmero: o servidor não
guarda nem reenvia histórico após reconexão.

Não há `leave`, retomada de sessão nem refresh de token no protocolo atual:
para sair, feche o WebSocket e todas as conexões WebRTC. Reconexão cria sessão
nova, obtém `members` novamente e refaz SDP/ICE; não reutilize candidatos,
`epoch` nem estatísticas da sessão anterior. Uma conexão antiga ainda ativa com
o mesmo usuário pode receber `already_joined`; feche-a e use backoff com
jitter antes de tentar novamente. Não salve token em URL, logs ou storage
persistente sem política de segurança definida.

O servidor aceita mensagens JSON de até **20 KiB**, no máximo **32 mensagens/s
por WebSocket**, e fecha a conexão em abuso (1008 para rate limit, 1009 para
frame grande). `auth`/`join`/`members` e as mensagens abaixo exigem campos
exatos; não acrescente `user`, `room`, IDs de requisição ou extensões próprias.
Respostas `{"type":"error","reason":"..."}` não trazem ID de correlação;
serialize operações de negociação por transporte e trate razões desconhecidas
como erro genérico. Nunca mostre SDP, candidatos ou tokens no erro da UI.

## Contrato de sinalização e mídia

Todos os exemplos seguintes são JSON enviados **após `joined`**. `description`
tem exatamente `type` (`offer` ou `answer`) e `sdp` (até 16 KiB). SDP SFU deve
oferecer um m-line `audio` seguro (`UDP/TLS/RTP/SAVPF` e fingerprint SHA-256).

| Direção | Mensagem | Uso |
|---|---|---|
| cliente → servidor | `{"type":"signal","to":"bob","description":{"type":"offer","sdp":"..."}}` | Oferta/resposta P2P; o servidor entrega a Bob como `signal` com `from:"alice"`. |
| cliente → servidor | `{"type":"signal","to":"bob","candidate":{...}}` | Candidato ICE P2P; mesma retransmissão com `from`. |
| cliente → servidor | `{"type":"media_offer","transport":"alice","publisher":"alice","sdp":{"type":"offer","sdp":"..."}}` | Publicar na SFU. Para assinar Bob, usar `transport:"bob", publisher:"bob"` e oferta `recvonly`. |
| servidor → cliente | `{"type":"media_answer","transport":"bob","publisher":"bob","sdp":{"type":"answer","sdp":"..."}}` | Aplicar ao transporte SFU correspondente. |
| ambos os sentidos | `media_candidate` com `transport` e `candidate` | ICE do transporte SFU; a mensagem vinda do servidor inclui também `publisher`. |
| servidor → cliente | `media_state` com `transport`, `publisher`, `state` | Diagnóstico da conexão SFU; não confirma áudio recebido. |
| servidor → cliente | `media_failed` | Sessão de mídia do usuário caiu; descartar os transportes SFU antigos e renegociar. P2P independente pode continuar. |

O objeto `candidate` usa `candidate` (string até 2 KiB), `sdpMid`,
`sdpMLineIndex` e, se disponível, `usernameFragment`. Para a SFU, inclua
`sdpMid` e `sdpMLineIndex` (m-line 0). **Não** envie `null` como mensagem de
fim de candidatos: esse marcador não possui contrato no servidor. O cliente
pode aguardar o fim de ICE gathering antes de enviar SDP ou usar candidatos
trickle válidos depois da oferta. Preserve a ordem oferta → candidatos.

Para evitar ofertas P2P simultâneas, **recomendado:** entre dois IDs, o menor
em ordem lexicográfica inicia a oferta inicial; o outro responde. O servidor
apenas retransmite e não resolve glare. Se houver renegociação/ICE restart,
serialize-a por par e mantenha a mesma regra de iniciador. A SFU atual não
substitui um transporte já criado (`transport_exists`); ICE restart/renegociação
SFU dentro da sessão é uma **lacuna**. Não construa um loop infinito de ofertas
ao receber esse erro.

## Métricas e seleção de rota

O **destinatário**, não o publicador, reporta cada conexão recebida:

```json
{"type":"route_metrics","publisher":"alice","route":"p2p","metrics":{"sequence":17,"window_ms":1000,"rtt_ms":null,"jitter_ms":8.2,"loss":0.01,"packets":48,"ice":"connected","dtls":"connected"}}
```

O mesmo formato vale para `route:"sfu"`. `sequence` deve crescer por rota;
`packets` é a quantidade recebida **na janela**, `loss` é fração entre 0 e 1,
e `rtt_ms` pode ser `null` quando não medido. RTT não é atraso de áudio em um
sentido. Converter jitter e RTT das unidades da API WebRTC para **ms**; não
comparar contadores acumulados com taxas por janela. Normalizar ICE
`completed` para `connected`. Os únicos estados enviados são ICE
`connected|failed|disconnected` e DTLS `connected|failed|connecting`.

O servidor exige janela de 100–60.000 ms, amostras novas em até 3 s, pelo
menos 5 pacotes por janela para marcar rota saudável, e usa inicialmente
limites de RTT 300 ms, jitter 30 ms e perda 5%. A rota SFU conectada com zero
pacotes pode ser **preparada**, mas não ativada sem confirmação de mídia.
Recomendado para seis pessoas: amostrar cada transporte recebido a ~1 Hz,
escalonar envios e reservar espaço no limite de 32 mensagens/s para SDP/ICE.
O limite de 24 participantes da sala **não** significa que 46 fluxos de
telemetria a 1 Hz cabem numa única conexão.

## Máquina de estados de reprodução por publicador

O servidor envia `route_prepare`, `route_commit`, `route_active` e
`route_rollback`, sempre com `publisher`, `epoch` e `route`. O cliente mantém
`{active, pending, epoch}` **para cada publicador**:

1. Em `route_prepare`: manter a rota antiga audível. O transporte candidato
   deve **já estar conectado e reportado**; iniciá-lo só agora pode estourar o
   timeout. Para SFU, o servidor libera o encaminhamento nesse
   momento; ICE/DTLS conectado, `ontrack` ou SDP respondido **não** bastam.
   Somente após observar pacotes/frames **novos e decodificáveis** na rota alvo,
   enviar `{"type":"route_ready","publisher":"alice","epoch":4,"route":"sfu"}`.
2. Em `route_commit` da mesma época: selecionar **atomicamente** a nova track
   para reprodução, silenciando a anterior, e então enviar
   `{"type":"route_ack","publisher":"alice","epoch":4}`. Não reproduzir
   as duas. Se a rota alvo já não estiver pronta, não confirmar cegamente;
   manter a anterior e aguardar rollback/timeout.
3. Em `route_active`: registrar a confirmação do servidor, manter a saída
   escolhida e deixar a conexão antiga aquecida apenas se o orçamento de CPU
   permitir. Em `route_rollback`: restaurar a rota indicada (ou silenciar se
   não houver rota anterior), descartar a pendência e ignorar mensagens da
   época antiga. O servidor usa timeout de 3 s para preparação/commit.
4. Em `peer_left`: fechar os transportes daquele publicador, remover áudio e
   estado de rota. Em perda do WebSocket/sala: silenciar e limpar toda a
   sessão; não continuar reproduzindo áudio sem autorização atual.

No navegador, **recomendado:** uma saída Web Audio ou elemento lógico por
publicador, com duas entradas mutuamente exclusivas (P2P/SFU). Um pequeno
ramp de ganho pode evitar estalo, mas sobrepor as duas tracks pode criar eco.
Os transportes têm SSRC, números de sequência RTP e timestamps independentes:
**não** deduplique comparando apenas esses campos. O laboratório T12 usa
marcadores acústicos próprios para teste; o cliente de produção ainda precisa
validar continuidade audível, gaps e duplicação sob troca real. A maior lacuna
local já observada foi 477 ms: não prometer troca imperceptível.

## Segurança, falhas e critérios do primeiro cliente

- O cliente nunca implementa ICE, DTLS, SRTP ou criptografia próprios; usa a
  pilha WebRTC da plataforma, WSS e validação normal de certificados.
- Credenciais TURN, quando disponíveis, devem ser provisionadas fora deste
  protocolo e protegidas como segredos temporários. O servidor atual não
  fornece TURN nem foi validado em NAT público.
- SDP, ICE, `media_state` e `error` são dados não confiáveis: validar forma,
  limitar armazenamento/logs e tratar desconexões/ordem inesperada sem crash.
- Não enviar áudio para outro usuário/sala fora dos IDs obtidos em `members`;
  o servidor também valida associação, mas a UI deve refletir a sala atual.
- Mostrar separadamente “conectado ao servidor”, “WebRTC conectado” e “áudio
  recebido”. Nenhum deles sozinho prova reprodução audível.

Aceite mínimo do cliente: autenticar/entrar; duas pessoas com P2P/Opus; duas
via SFU/Opus quando o direto falha; seis na sala com ao menos uma rota SFU
seletiva; troca P2P→SFU→P2P sem áudio duplo; limpeza após `peer_left`, queda do
WebSocket e `media_failed`; métricas reais e gaps de reprodução registrados.
Executar esses testes com **o novo cliente**, não apenas com `lab/worker.py`.
Browser, TURN/NAT público, renovação de credenciais e reprodução sem lacunas
permanecem **não verificados** pelo repositório atual.
