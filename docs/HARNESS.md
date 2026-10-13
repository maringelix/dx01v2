# Harness do dx01v2

O harness é o conjunto de checks que prova o que este repositório afirma, sem conta na nuvem.
Ele vive em `scripts/harness.sh`; o `Makefile` e o CI só o chamam. O que passa localmente com
`HARNESS_STRICT=1` passa no CI.

## Camadas

| Camada | Comando | O que prova | O que NÃO prova | Onde roda |
|---|---|---|---|---|
| Ferramentas | `make tools` | binários nas versões de `tools/versions.env`, SHA256 conferido | — | local, CI |
| Versões | `tool-versions`, `version-consistency` | PATH com as versões fixadas (estrito); Node.js, PostgreSQL e Kubernetes coerentes entre arquivos; versões npm exatas | — | local, CI |
| Estrutura e honestidade | `repo-structure` | arquivos obrigatórios, rótulos de status, LF, README <= 250 linhas, bit executável dos scripts no índice do git | que a documentação está certa | local, CI |
| Políticas | `policy-identifiers`, `policy-workflows`, `policy-images`, `policy-app`, `trivyignore-policy` | sem IDs reais; actions e imagens fixadas; regressões do v1 (trust proxy, CORS, estilos inline, HSTS, `console.*`); ignores com validade | intenção de quem escreveu | local, CI |
| Dependências | `npm-ci` | `package-lock.json` em sincronia com os três `package.json` (no modo estrito sempre roda `npm ci`) | que as dependências são seguras (ver trivy) | local, CI |
| Lint, formato e tipos | `eslint`, `prettier`, `typecheck:api`, `typecheck:web` | regras type-aware do typescript-eslint, React hooks, formatação, TypeScript estrito | comportamento | local, CI |
| Dockerfiles, workflows e scripts | `hadolint`, `actionlint` (com shellcheck), `shellcheck` | boas práticas de Dockerfile, YAML e bash corretos (nível style) | comportamento contra a nuvem | local, CI |
| Manifests | `kubeconform`, `contract-app`, `trivy-config` | overlays `local`, `aws` e `aws-https` renderizados e válidos (estrito, Kubernetes 1.36, CRD do ESO); asserções do contrato v1 e de hardening (`scripts/check-manifests.mjs`); sem HIGH/CRITICAL de configuração | admission e comportamento no cluster (ver e2e) | local, CI (rede) |
| Segredos | `gitleaks` | nenhum segredo conhecido (histórico completo quando há commits) | segredos fora dos padrões do gitleaks | local, CI |
| Testes da API | `test:api` | unitários e de integração com supertest contra o app real e um PostgreSQL 17 real: migrações idempotentes, fluxos de criar/listar/apagar, 400/401/404/413/415/429/503, XFF falso não fura o limite, readyz 200/503, recuperação do banco, desligamento gracioso; cobertura >= 80 % linhas e >= 70 % branches | TLS com o RDS, várias réplicas | local, CI (Docker ou `DB_*`) |
| Testes da página | `test:web` | lista, envio com sucesso e erro, validação, modo admin (fetch simulado), cobertura >= 70 % linhas | navegador real, CSP aplicada pelo navegador | local, CI |
| Build | `npm-build`, `image:*`, `image-policy:*` | `tsc` e `vite build`; as duas imagens; usuário numérico não root, labels OCI, sem npm/npx/corepack nem shell no runtime da API | comportamento em runtime (ver e2e) | local, CI (Docker) |
| Vulnerabilidades das imagens | `trivy-image:*` | nenhuma HIGH/CRITICAL com correção disponível | CVEs sem correção, zero-days | local, CI (Docker, rede) |
| Ponta a ponta | `kind-e2e` (`scripts/e2e-kind.sh`) | cluster kind 1.36: rollouts com initContainer de migração, Pod Security `restricted` imposto, smoke test pelo nginx (cabeçalhos, API, 201/400/401/204/404/413/429, XFF falso, request ID) e sondas de NetworkPolicy (permitido/bloqueado) | EKS, ALB, WAF, ESO, RDS, VPC CNI | local, CI (Docker) |
| Nuvem | workflow `deploy-aws`, `scripts/deploy-aws.sh` | — | — | `não executado em nuvem (v2)` |

O smoke do compose (`scripts/compose-smoke.sh`) usa o mesmo `e2e/smoke.mjs`, mas roda à mão (fora
do CI): ver `docs/RUNBOOK.md`.

## Jobs do CI

| Job (`ci.yml`) | Alvo | Estágio do harness |
|---|---|---|
| `static` | `make tools && make static` | `static` |
| `test` | `make test` (service `postgres:17-alpine` por digest, `DB_*` no ambiente) | `test` |
| `images` | build com buildx + cache do GitHub Actions, depois `make tools && make build` com `IMAGES_PREBUILT=1`; as duas imagens viram um artefato | `build` |
| `e2e` | carrega o artefato, `bash scripts/install-tools.sh kind kubectl`, `make e2e` com `E2E_SKIP_BUILD=1`; diagnósticos como artefato em caso de falha | `e2e` |
| `e2e-platform` | carrega o artefato, `make e2e-platform` com `E2E_SKIP_BUILD=1`: clona o tx01v2 no commit de `deploy/local/tx01v2.ref`, sobe o lab local completo, faz o deploy GitOps e roda as sondas (`docs/LAB_LOCAL.md`); diagnósticos como artefato | `platform` |

Os ids `static`, `test`, `images` e `e2e` são estáveis: são os checks exigidos pelo ruleset
(`.github/rulesets/main.json`); o check `policy-workflows` impede que mudem sem querer. O
`e2e-platform` roda em todo PR e precisa estar verde para o merge (disciplina do mantenedor; ainda fora
do ruleset). Checks novos: `promtool-rules` (estático: `promtool check rules` e `promtool test rules`
das regras de alerta do overlay `local-platform`) e `platform-e2e` (estágio `platform`).

## Modo estrito

`HARNESS_STRICT=1` (definido no CI e no devcontainer) transforma todo `SKIP` em `FAIL`, exige que as
versões no PATH sejam as de `tools/versions.env` e sempre roda `npm ci`. Sem ele, um check só pode
dar `SKIP` quando falta um pré-requisito local (ferramenta não instalada, Docker parado) e sempre
imprime o motivo.

Outras variáveis:

| Variável | Efeito |
|---|---|
| `HARNESS_VERBOSE=1` | mostra a saída dos checks que passam |
| `HARNESS_ONLY=<regex>` | roda só os checks cujo nome casa (depuração local; o CI nunca usa), por exemplo `HARNESS_ONLY='^eslint$' scripts/harness.sh static` |
| `HARNESS_WORK_DIR` | logs, manifests renderizados e caches (padrão `$TMPDIR/dx01v2-harness`) |
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | banco dos testes de integração; sem `DB_HOST`, o harness sobe um `postgres:17-alpine` descartável (porta aleatória em 127.0.0.1) e o remove no fim |
| `IMAGE_TAG` | tag das imagens construídas e escaneadas (padrão `e2e`, a que o overlay `local` usa) |
| `IMAGES_PREBUILT=1` | o estágio `build` confere imagens construídas por fora (CI) em vez de construí-las |
| `E2E_SKIP_BUILD=1`, `KEEP_CLUSTER=1`, `E2E_DIAGNOSTICS_DIR`, `E2E_KIND_INTERNAL=1` | ver o cabeçalho de `scripts/e2e-kind.sh` |

## Como adicionar um check

1. Escreva uma função `check_<nome>` em `scripts/harness.sh` que retorna 0 (PASS) ou não-zero (FAIL);
   use `need <ferramenta>`, `need_docker` ou `skip "<motivo>"` só para pré-requisitos ausentes;
   `summary "<texto>"` imprime uma linha de resultado mesmo quando o check passa.
2. Registre-a em `register_checks` no estágio certo (`static`, `test`, `build` ou `e2e`).
3. Rode `scripts/harness.sh list` e `HARNESS_STRICT=1 make verify` (e o estágio do check).
4. Atualize esta tabela, `docs/GUARDRAILS.md` (se for um guardrail) e o CHANGELOG.

Ferramenta nova: adicione-a a `scripts/lib/tools.sh` (URLs oficiais), a `tools/versions.env` e rode
`scripts/update-tool-checksums.sh <ferramenta> <versão>`.

## Windows e macOS

- Windows: use o devcontainer (`.devcontainer/devcontainer.json`: Node.js 24 + Docker-in-Docker,
  imagem e feature fixadas por digest) ou WSL 2 com Ubuntu. Git Bash não é suportado (as ferramentas
  são binários Linux/macOS).
- macOS (Apple Silicon): `brew install bash` (o bash 3.2 do sistema não serve; o harness exige
  bash >= 4.4) ou o devcontainer. Plataformas suportadas pelo `install-tools.sh`: linux_amd64,
  linux_arm64, darwin_arm64.
- Container avulso com o Docker do host (como a verificação local deste repositório): uma imagem
  `node:24` (Debian) com o cliente Docker, o repositório em `/work`, o socket do Docker e volumes
  nomeados para `node_modules` e `.tools` (fora de pastas sincronizadas como OneDrive):
  ```bash
  docker run --rm -e HARNESS_STRICT=1 -v "$PWD:/work" -w /work \
    -v dx01v2-nm-root:/work/node_modules -v dx01v2-nm-api:/work/api/node_modules \
    -v dx01v2-nm-web:/work/web/node_modules -v dx01v2-tools:/work/.tools \
    -v /var/run/docker.sock:/var/run/docker.sock --network <rede com o PostgreSQL> \
    -e DB_HOST=<container do PostgreSQL> -e DB_NAME=... -e DB_USER=... -e DB_PASSWORD \
    <imagem node:24 com o cliente docker> bash -c "make tools && make verify build"
  ```
  Dentro de um container, o PostgreSQL descartável do harness e o `127.0.0.1` publicado pelo kind
  pertencem ao host: passe `DB_*` apontando para um PostgreSQL na mesma rede Docker e, no e2e, use
  `E2E_KIND_INTERNAL=1` (o script entra na rede `kind` e usa o endereço interno do API server).
  Adicione `-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=*` se o
  dono dos arquivos for outro usuário.

## Dados fora do repositório

O harness grava logs, manifests renderizados, a árvore copiada para o gitleaks e os caches do trivy
e do kubeconform em `HARNESS_WORK_DIR` (padrão `$TMPDIR/dx01v2-harness`). No repositório ficam só
`.tools/`, `node_modules/`, `*/dist/` e `*/coverage/` (todos ignorados pelo git). `make clean`
remove tudo isso.

## Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `SKIP tool-versions - missing tools` | `make tools` não rodou | `make tools` |
| `FAIL npm-ci` | `package-lock.json` fora de sincronia com algum `package.json` | `npm install` (gera o lock) e commit dos dois; nunca edite o lock à mão |
| `FAIL test:api` com `integration tests need DB_HOST...` | sem Docker e sem `DB_*` | inicie o Docker ou exporte `DB_*` para um PostgreSQL 17 |
| `FAIL test:api` com `ERROR: Coverage for lines (...) does not meet` | código novo sem teste | escreva o teste; nunca baixe o limite |
| `FAIL trivy-image:*` | CVE HIGH/CRITICAL com correção nova | `docs/SUSTENTACAO.md`, seção 5.6 |
| `FAIL trivyignore-policy ... expired` | ignore venceu | revise a exceção: corrija ou renove com nova justificativa |
| `FAIL kubeconform ... could not find schema` | sem rede, ou schema do catálogo que o kubeconform não compila | confira a rede; os commits dos catálogos estão fixados em `scripts/harness.sh` |
| `FAIL contract-app` | manifest divergente do contrato v1 ou do hardening | corrija o manifest; mudança de contrato exige PR coordenado com o tx01v2 |
| `FAIL kind-e2e` | rollout, smoke ou sonda falhou | leia o resumo e os diagnósticos (`E2E_DIAGNOSTICS_DIR`, artefato `e2e-diagnostics` no CI); `KEEP_CLUSTER=1 make e2e` para investigar |
| `FAIL gitleaks` | segredo ou falso positivo | remova o segredo e gire a credencial; placeholders devem ter cara de placeholder (por exemplo SHA só com zeros). Antes do primeiro commit o check examina os arquivos visíveis ao git |
| `FAIL policy-identifiers` | ID de conta, e-mail ou IP real | use `123456789012`, `you@example.com`, `203.0.113.10/32` |
