# Laboratório de rede local

Requer Docker Engine com Compose v2, acesso para baixar imagens/dependências e
suporte a `NET_ADMIN` nos contêineres de clientes e de emulação. Na raiz:

```sh
docker compose -f compose.test.yaml up --build --abort-on-container-exit --exit-code-from test-runner
```

O código de saída é o do `test-runner`. Para um subconjunto:
`SCENARIOS=T01,T02 docker compose -f compose.test.yaml up --build --abort-on-container-exit --exit-code-from test-runner`.
No PowerShell, use `$env:SCENARIOS='T01,T02'` antes do comando. O runner grava
`lab/results/results.json`, ignorado pelo Git. Execute apenas nessa rede
Docker privada; a API HTTP de controle dos peers e os tokens de
`lab/credentials.lab.json` são fixtures locais, nunca credenciais de produção.
T08 encerra um contêiner de propósito e roda separadamente com
`docker compose -f compose.test.yaml run --rm -e SCENARIOS=T08 test-runner`;
inseri-lo no `up --abort-on-container-exit` aborta todos os serviços antes da
asserção. Os workflows executam ambos os comandos automaticamente.

Há seis contêineres aiortc. Cada peer pode hospedar até quatro clientes no
teste de 24. `tc` instala um qdisc de saída em `eth0` com filtro de destino
IPv4 e protocolo UDP; assim o WebSocket TCP de sinalização continua disponível.
Para T02/T03, o destino é o outro peer. Para T04, o destino é a SFU. A
degradação de um sentido não demonstra perda simétrica; T02 configura os dois.
`network-emulation` compartilha o namespace de rede do servidor e aplica `tc`
ao UDP servidor→peer no teste de rollback. Só esse processo tem `NET_ADMIN`
nesse namespace; o servidor não tem a capacidade. O filtro é removido após
cada cenário. A rede Compose é `internal`; não há
porta publicada no host.

Diagnóstico: confira `docker compose -f compose.test.yaml logs beamvoice-server
peer-a test-runner`; falha em `tc` pode indicar Docker sem NET_ADMIN; falha
ICE com candidatos privados fora dessa rede exige TURN/topologia própria.
Os clientes precisam da imagem com aiortc/Opus; envio UDP simples não substitui
WebRTC. O primeiro build compila NIFs de DTLS/SRTP e pode demorar.

O servidor tem limite de 2 CPUs e 512 MiB; cada peer de teste tem CPU/memória
separadas. Esse limite não reproduz fielmente a latência ou interferência de
uma VPS. `docker stats` e `/metrics` (Bearer token da fixture) auxiliam
análise externa; a rota de métricas não deve ser exposta publicamente.
