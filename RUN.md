# Compilar, executar e medir Rust e Swift

Este guia usa os dois checkouts lado a lado e Docker para compilar os servidores.
Não é necessário instalar Swift na máquina. O gerador de carga é escrito em Rust
e usa o Cargo instalado no host.

## 1. Pré-requisitos e caminhos

Ambiente usado: Linux, Bash, Docker com acesso pelo usuário atual, Python 3,
`curl`, `taskset`, Git e Rust/Cargo 1.98.1. O runner de benchmark espera cgroup v2
com os containers Docker em `/sys/fs/cgroup/system.slice/docker-<id>.scope`.

Defina os caminhos em cada terminal utilizado; ajuste `CAMPFIRE_ROOT` se mover os
checkouts:

```bash
export CAMPFIRE_ROOT=/home/piero/libs/once-campfire
export RUST_ROOT="$CAMPFIRE_ROOT/once-campfire-rust"
export SWIFT_ROOT="$CAMPFIRE_ROOT/once-campfire-swift"
export SEED_DIR="$RUST_ROOT/parity/.seed/default"
export PERF_TOOLS="$SWIFT_ROOT/bench/results/key-cache-20261006"

docker info >/dev/null
cargo --version
taskset -pc $$
lscpu -e=CPU,CORE,SOCKET,ONLINE
```

Os comandos de benchmark abaixo reservam CPUs `0-3` para o servidor e `4-7` para
o cliente. Ajuste ambas as listas se não estiverem disponíveis. Mantenha a mesma
alocação para Rust e Swift, sem sobreposição entre cliente e servidor.

Se o Rust estiver disponível somente pelo mise, entre em um shell configurado
com `mise exec rust@1.98.1 -- bash` antes de executar os comandos que usam Cargo
ou o runner, que chama Cargo internamente.

## 2. Atualizar os checkouts e os submódulos

Para medir exatamente o código local, pule os dois `git pull`. Para atualizar,
execute com os checkouts sem alterações locais conflitantes:

```bash
git -C "$RUST_ROOT" pull --ff-only
git -C "$SWIFT_ROOT" pull --ff-only
git -C "$RUST_ROOT" submodule update --init --recursive
git -C "$SWIFT_ROOT" submodule update --init --recursive
```

O submódulo `reference/` é necessário para os assets das duas compilações.

## 3. Preparar a mesma base de dados

O seed do repositório Rust contém SQLite, arquivos e credenciais de teste. Ambos
os servidores usam esse mesmo seed. A geração usa Rails dentro do Docker:

```bash
cd "$RUST_ROOT"
PARITY_RUNTIME=docker parity/bin/reference build
PARITY_RUNTIME=docker parity/bin/seed build default

test -f "$SEED_DIR/db/production.sqlite3"
test -f "$SEED_DIR/labels.json"
```

Esta etapa pode ser pulada se o seed já existir e você quiser reutilizar o mesmo
conjunto de dados. A geração substitui o seed `default` existente. Não use o seed
original como volume gravável dos servidores; use cópias, como nas próximas etapas.
O arquivo `parity/.env.reference` fornece os segredos locais de teste.

## 4. Compilar os dois servidores e o gerador de carga

```bash
docker build -t campfire-rust:app "$RUST_ROOT"
docker build -t campfire-swift:app "$SWIFT_ROOT"
docker tag campfire-swift:app campfire-swift:optimized

CARGO_TARGET_DIR="$RUST_ROOT/target/bench" \
  cargo build --release --locked \
  --manifest-path "$RUST_ROOT/bench/loadgen/Cargo.toml"
```

As imagens são as unidades de execução: incluem o binário e suas bibliotecas de
runtime. Dentro delas, os executáveis ficam em `/usr/local/bin/campfire` (Rust) e
`/usr/local/bin/campfire-swift` (Swift). O loadgen fica no host em
`$RUST_ROOT/target/bench/release/loadgen`. As três compilações usam modo release.

## 5. Executar manualmente

Prepare diretórios independentes para as duas aplicações. O script também
redireciona push e webhooks do seed para uma porta local fechada, como o benchmark:

```bash
export RUN_WORK=$(mktemp -d "$CAMPFIRE_ROOT/run-local.XXXXXX")

python3 - <<'PY'
import os, shutil, sqlite3
from pathlib import Path
seed = Path(os.environ['SEED_DIR'])
work = Path(os.environ['RUN_WORK'])
for app in ('rust', 'swift'):
    directory = work / app
    shutil.copytree(seed / 'db', directory / 'db')
    shutil.copytree(seed / 'storage', directory / 'files')
    with sqlite3.connect(directory / 'db/production.sqlite3') as db:
        db.execute("UPDATE push_subscriptions SET endpoint = 'https://127.0.0.1:9/push/' || id")
        db.execute("UPDATE webhooks SET url = 'http://127.0.0.1:9/hook/' || id")
PY

docker run -d --name campfire-rust-local \
  --user "$(id -u):$(id -g)" \
  --env-file "$RUST_ROOT/parity/.env.reference" \
  -e HTTP_PORT=80 -e TARGET_PORT=3000 \
  -p 127.0.0.1:8081:80 \
  -v "$RUN_WORK/rust/db:/rails/storage/db" \
  -v "$RUN_WORK/rust/files:/rails/storage/files" \
  campfire-rust:app

docker run -d --name campfire-swift-local \
  --user "$(id -u):$(id -g)" \
  --env-file "$RUST_ROOT/parity/.env.reference" \
  -e HTTP_PORT=80 \
  -p 127.0.0.1:8082:80 \
  -v "$RUN_WORK/swift/db:/rails/storage/db" \
  -v "$RUN_WORK/swift/files:/rails/storage/files" \
  campfire-swift:app

curl --fail --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:8081/up
curl --fail --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:8082/up
```

Abra Rust em <http://127.0.0.1:8081> e Swift em <http://127.0.0.1:8082>.
As credenciais estão nas entradas `emails.david` e `passwords.all` de
`$SEED_DIR/labels.json`. Para diagnóstico, use `docker logs campfire-rust-local`
ou `docker logs campfire-swift-local`.

Antes de medir performance, pare os dois servidores manuais:

```bash
docker stop campfire-rust-local campfire-swift-local
docker rm campfire-rust-local campfire-swift-local
```

Os dados dessa execução ficam em `$RUN_WORK`; o seed original permanece intacto.

## 6. Benchmark Rust versus Swift

Execute sem compilações ou outros testes concorrentes. Não rode dois benchmarks
ao mesmo tempo: o runner compartilha `bench/.work`. A porta `4490` deve estar livre.

```bash
export RESULTS="$CAMPFIRE_ROOT/benchmark-results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS"

CAMPFIRE_RUST_ROOT="$RUST_ROOT" \
RUST_IMAGE=campfire-rust:app SWIFT_IMAGE=campfire-swift:app \
SERVER_CPUS=0-3 LOADGEN_CPUS=4-7 \
HTTP_SECS=8 HTTP_CONCS='16' SUITES=http \
LOAD_MAX=10 LOAD_WAIT_SECS=30 PORT=4490 \
  "$PERF_TOOLS/run-http" \
  --apps rust,swift-after --reps 3 --out "$RESULTS"

git -C "$RUST_ROOT" rev-parse HEAD > "$RESULTS/rust-commit.txt"
git -C "$SWIFT_ROOT" rev-parse HEAD > "$RESULTS/swift-commit.txt"
git -C "$RUST_ROOT" diff HEAD > "$RESULTS/rust-local.diff"
git -C "$SWIFT_ROOT" diff HEAD > "$RESULTS/swift-local.diff"
```

`swift-after` é o nome que o runner atribui à imagem indicada por `SWIFT_IMAGE`.
Ele compila o loadgen, inicia um servidor por vez, alterna a ordem entre rodadas,
restaura uma cópia do seed para cada execução e aplica a mesma configuração de
processos. Cada endpoint tem 2 segundos de aquecimento e 8 segundos de medição.
São medidos:

| Nome no JSON | Operação |
|---|---|
| `room_show` | Página da sala |
| `messages_page` | Página de mensagens anteriores |
| `sidebar` | Sidebar do usuário |
| `search` | Busca por `coffee` |
| `post_message` | Postagem de mensagem |

O resultado inclui `rust-1.json` a `rust-3.json`, `swift-after-1.json` a
`swift-after-3.json`, IDs das imagens em `env.txt`, carga do host em `uptime.log`,
latências, inicialização e memória. Os containers do benchmark são removidos pelo
runner. Use um diretório novo a cada experimento para não misturar resultados.

### Validar e resumir os resultados dos dois

O comando abaixo exige três rodadas completas, os cinco endpoints, HTTP 200 em
todas as requisições medidas e nenhum erro de transporte. Depois imprime medianas
de throughput e latência p99, além do intervalo de throughput entre rodadas:

```bash
python3 - "$RESULTS" <<'PY'
import json, statistics, sys
from pathlib import Path
root = Path(sys.argv[1])
apps = ('rust', 'swift-after')
routes = ('room_show', 'messages_page', 'sidebar', 'search', 'post_message')
data = {}
for app in apps:
    files = sorted(root.glob(f'{app}-*.json'))
    assert len(files) == 3, f'{app}: esperado 3 arquivos, encontrados {len(files)}'
    runs = [json.loads(file.read_text()) for file in files]
    assert sorted(run['rep'] for run in runs) == [1, 2, 3]
    for run in runs:
        assert len(run['http']) == 5
        assert {row['route'] for row in run['http']} == set(routes)
        for row in run['http']:
            assert row['conc'] == 16
            assert row['errors'] == 0 and set(row['statuses']) == {'200'}, row
            assert row['latency']['n'] > 0 and row['rps'] > 0, row
    data[app] = runs
print('PASS: todas as amostras válidas. Throughput em req/s; p99 em ms.')
print('| Endpoint | Rust mediana [min–max] | Swift mediana [min–max] | p99 Rust / Swift | Rust / Swift |')
print('|---|---:|---:|---:|---:|')
for route in routes:
    samples = {app: [next(row for row in run['http'] if row['route'] == route)
                     for run in data[app]] for app in apps}
    medians = {}
    cells = []
    for app in apps:
        values = [row['rps'] for row in samples[app]]
        medians[app] = statistics.median(values)
        cells.append(f'{medians[app]:.1f} [{min(values):.1f}–{max(values):.1f}]')
    latency = [statistics.median(row['latency']['p99_ms'] for row in samples[app]) for app in apps]
    print(f'| {route} | {cells[0]} | {cells[1]} | {latency[0]:.2f} / {latency[1]:.2f} | {medians["rust"] / medians["swift-after"]:.2f}× |')
PY
```

Mais req/s é melhor; menos latência é melhor. Compare também p50, p90 e memória
nos JSONs. O ganho de throughput não garante melhora na cauda de latência: na
medição registrada, por exemplo, a postagem Swift aumentou throughput, mas p99
ficou maior. A validade funcional desses endpoints não valida todos os recursos
do aplicativo.

Para uma análise mais longa, aumente `HTTP_SECS` e o número de repetições, adaptando
a contagem no resumo. Para reproduzir a medição registrada, mantenha os parâmetros
acima. `LOAD_MAX=10` e espera de 30 segundos reproduzem aquele experimento; a espera
é limitada e não garante host ocioso. Confira `env.txt` e `uptime.log`, repita se a
carga variar muito e mantenha CPUs, seed, compressão e ambiente iguais. O runner
mede HTTP com gzip; não compare diretamente com medições em `identity`.

WebSockets, uploads e assets auxiliares não fazem parte deste runner adaptado.
O 404 de CSS observado anteriormente no Swift não foi corrigido pelas otimizações.

## 7. Validação rápida e testes do Swift

Após compilar o loadgen, estes checks exercitam os gargalos corrigidos. Eles usam
CPUs fixas `0-3` e `4-7`, porta `4590`, uma cópia temporária do seed e removem o
container ao terminar:

```bash
python3 "$PERF_TOOLS/check-throughput.py" campfire-swift:app sidebar
python3 "$PERF_TOOLS/check-throughput.py" campfire-swift:app messages_page
```

`PASS` exige HTTP 200, zero erros, pelo menos 100 req/s na sidebar e 500 req/s em
mensagens. São checks curtos de regressão nessa configuração, não metas universais
nem substitutos da comparação de três rodadas.

Para executar os testes Swift sem instalar o toolchain no host:

```bash
docker build --target build -t campfire-swift:build "$SWIFT_ROOT"
docker run --rm --entrypoint bash \
  -e CAMPFIRE_SEED_DIR=/seed -e CAMPFIRE_REQUIRE_SEED=1 \
  -v "$SEED_DIR:/seed:ro" \
  campfire-swift:build \
  -lc 'swift test -j 2 -c release'
```

O seed obrigatório impede que a ausência da base seja tratada como teste pulado.
Na revisão atual foram executados 39 testes, sem falhas (inclui testes diferenciais
que comparam os parsers/formatadores de data rápidos com Foundation e com o SQLite).

## 8. Reproduzir Swift antes/depois junto com Rust

A imagem original local foi preservada como `campfire-swift:baseline-65a938d`, e a
otimização anterior (commit `32f31f8`) como `campfire-swift:key-cache-32f31f8`.
Se precisar reconstruí-la, use um worktree separado para não trocar o código atual:

```bash
export BASELINE_WORK=$(mktemp -d "$CAMPFIRE_ROOT/swift-baseline.XXXXXX")
git -C "$SWIFT_ROOT" worktree add --detach "$BASELINE_WORK" 65a938d
git -C "$BASELINE_WORK" submodule update --init --recursive
docker build -t campfire-swift:baseline-65a938d "$BASELINE_WORK"
```

Com as imagens original e otimizada presentes, compare respostas de leitura:

```bash
docker tag campfire-swift:app campfire-swift:optimized
python3 "$PERF_TOOLS/check-response-parity.py"
```

O check usa as portas `4591` e `4592`, o mesmo Host e respostas sem compressão.
Exige conteúdo, status e headers selecionados, incluindo ETags, idênticos entre as
duas versões Swift. Ele não compara o HTML de Rust com Swift.

Para medir as três imagens, troque `--apps rust,swift-after` do passo 6 por
`--apps swift-before,swift-after,rust`. O relatório histórico e suas amostras estão
em [bench/results/key-cache-20261006/report.md](bench/results/key-cache-20261006/report.md).
O `summarize.py` desse diretório é específico de três imagens e das configurações
registradas; o resumo do passo 6 é para a comparação nova de duas imagens.

### Referência de performance desta máquina

Intel Core i7-1255U, harness `once-campfire-verification` (respostas validadas contra o
contrato de cada rota e escritas auditadas), três rodadas alternadas, 16 clientes, CPUs
`8-11` para o servidor e `4-7` para o cliente, gzip. Medianas em req/s:

| Endpoint | Swift original | Swift `32f31f8` | Swift `4d808fd` | Swift `505baf6` | Swift atual | C `135fc20` | Rust `9872c1d` |
|---|---:|---:|---:|---:|---:|---:|---:|
| Sala | 111,7 | 1.465,3 | 16.720,1 | 31.304,9 | 53.820,2 | 41.563,3 | 28.469,0 |
| Mensagens | 94,0 | 2.926,3 | 19.259,4 | 32.455,5 | 55.291,1 | 43.709,0 | 27.366,4 |
| Sidebar | 44,7 | 3.797,6 | 15.531,9 | 33.737,1 | 62.474,0 | 46.667,4 | 31.547,3 |
| Busca | 323,6 | 4.356,6 | 15.780,9 | 34.034,1 | 59.879,8 | 47.953,0 | 29.677,1 |
| Postagem | 116,6 | 288,6 | 3.196,8 | 3.297,7 | 3.146,0 | 1.647,0 | 2.300,3 |

As três primeiras colunas vêm do runner local antigo (`bench/results/key-cache-20261006`
e `wal-pages-20261006`), com o seed do Rust; as demais, do harness de verificação, com
o seed dele. "Swift atual" é a revisão com execução nos event loops e hits do cache
respondidos no pipeline do NIO; resultados em
`bench/results/verification-event-loop-20261009`.

Latência mediana nas leituras, Swift atual / C / Rust: p50 0,20–0,23 / 0,31–0,36 /
0,48–0,56 ms; p99 0,42–0,49 / 0,68–0,83 / 1,03–1,11 ms. Na postagem o p99 do Swift
oscila entre ~10 e ~40 ms de uma rodada para outra (checkpoints do WAL).

Para reproduzir, com as imagens construídas e o loadgen do harness compilado:

```bash
cd "$CAMPFIRE_ROOT/once-campfire-verification"
SWIFT_IMAGE=campfire-swift:app bin/benchmark --apps rust,swift,c --rounds 3 \
  --cpus 8-11 --client-cpus 4-7 \
  --routes room_show,messages_page,sidebar,search,post_message
```

O Swift ainda não serve os assets CSS nem a página `/up` do Rails, por isso a seleção de
rotas. São referências locais, não limites de aprovação para outras máquinas.
