# Resultados de benchmark

T11 foi executado localmente em 2026-10-16, com imagem final limitada a 2 CPUs
e 512 MiB no servidor e 1 CPU por contêiner de peer. Os oito casos passaram.
Artefato bruto: `lab/results/run-1792178081621713216.json`. O comando é
`SCENARIOS=T11 docker compose -f compose.test.yaml up --build
--abort-on-container-exit --exit-code-from test-runner` (em PowerShell,
configure `$env:SCENARIOS='T11'` antes). O runner cria 2/6/12/24 clientes,
frames de 10/20 ms, em anel P2P.

| Peers | Frame | CPU servidor¹ | Memória cgroup | Processos BEAM | Pior p95 de intervalo PCM² |
|---:|---:|---:|---:|---:|---:|
| 2 | 10 ms | 0,4% | 139,6 MiB | 155 | 21,2 ms |
| 2 | 20 ms | 1,6% | 137,9 MiB | 155 | 22,2 ms |
| 6 | 10 ms | 0,9% | 138,4 MiB | 169 | 22,6 ms |
| 6 | 20 ms | 1,3% | 138,8 MiB | 169 | 24,6 ms |
| 12 | 10 ms | 4,9% | 138,6 MiB | 187 | 27,3 ms |
| 12 | 20 ms | 1,7% | 138,7 MiB | 187 | 32,3 ms |
| 24 | 10 ms | 6,1% | 139,4 MiB | 223 | 87,2 ms |
| 24 | 20 ms | 5,3% | 139,7 MiB | 223 | 80,2 ms |

¹ 100% equivale a um vCPU; amostra de cinco segundos, não pico. O tráfego T11
é P2P, portanto a CPU da SFU e o encaminhamento RTP não são exercitados.
² Maior p95 entre fluxos recebidos, janela de até mil callbacks por fluxo,
incluindo estabelecimento; não é latência de rede nem de áudio ponta a ponta.
O aumento para ~80–87 ms em 24 peers aparece nos clientes compartilhados
(quatro peers por contêiner de 1 CPU). Não se pode atribuí-lo ao servidor sem
profiling adicional. A variação de CPU entre execuções de 10/20 ms impede
concluir que um tamanho de frame é mais eficiente nesta amostra curta.

T07, separado de T11, confirmou 30 fluxos dirigidos de uma malha P2P de seis
peers e comutou um deles para SFU. Na janela de cinco segundos com essa rota
SFU ativa: 50,0 pacotes RTP/s recebidos e 50,0 encaminhados, 0,0 descartados/s,
4,7% de um vCPU no cgroup do servidor, 138,2 MiB e 195 processos BEAM.
Artefato: `lab/results/run-1792178280540636895.json`. É **um único fluxo
SFU**, não prova que 30 fluxos SFU simultâneos cabem na VPS.

Em cada caso, após conexão, o runner observa cinco segundos de tráfego e lê
`/metrics` antes/depois: CPU do cgroup (`usage_usec`/tempo decorrido; 100% =
um vCPU), memória atual do cgroup, memória/processos BEAM e taxas RTP
recebida/encaminhada/descartada. Cada cliente informa contagem de PCM,
perda/jitter estimados pelo WebRTC e p50/p95/p99 dos intervalos entre callbacks
de decodificação (janela de até mil intervalos, incluindo estabelecimento).

Limitações: T07 cobre malha de seis com rota SFU mista, sem comparabilidade
direta com T11. Não há medição de latência de áudio ponta a ponta nem p95 de
encaminhamento efetivo na SFU; a meta de 5 ms permanece **NÃO VERIFICADA**.
Também faltam perfil de GC/mailbox durante períodos prolongados, distribuição
de CPU por processo e medição de banda fora do contêiner. O host Docker não
representa fielmente uma VPS de 2 vCPUs. Uma tentativa anterior falhou por
exigência equivocada do T07 ainda presente no T11; a condição foi removida e
os oito casos finais passaram. Artefatos com falha foram preservados.
