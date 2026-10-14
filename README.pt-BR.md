# dx01v2

Metade de aplicação de um lab de DevOps: um mural de mensagens pequeno (API Express 5, página React 19, PostgreSQL 17) com containers, manifests Kubernetes e um teste ponta a ponta em kind.

[![ci](https://github.com/maringelix/dx01v2/actions/workflows/ci.yml/badge.svg)](https://github.com/maringelix/dx01v2/actions/workflows/ci.yml)

[English](README.md)

**Fork do lab:** o [FORK.md](FORK.md) (em inglês) leva você do fork ao lab rodando, primeiro na sua máquina, depois na sua conta de nuvem.

## O que é

Um lab público e educacional para clonar ou fazer fork e aprender como um app web pequeno é
construído, testado, empacotado e publicado em Kubernetes com segurança. Tudo é provado por um
harness local que não precisa de conta na nuvem: lint, checagem de tipos, testes unitários e de
integração contra um PostgreSQL de verdade, build das imagens com gate de vulnerabilidades e um teste
ponta a ponta em um cluster kind local. O caminho AWS (EKS construído pelo `tx01v2`) está pronto, mas
**nunca rodou na nuvem** — a matriz de status diz exatamente o que está provado e como.

A família do lab (v2):

| Repositório | Nuvem | Papel | Status |
|---|---|---|---|
| [`tx00v2`](https://github.com/maringelix/tx00v2) | as três | hub da família: roadmap, guardrails da família, checks entre os repositórios | veja a matriz de status dele |
| [`tx01v2`](https://github.com/maringelix/tx01v2) | AWS | infraestrutura (Terraform, EKS, RDS, camada de plataforma) | veja a matriz de status dele |
| `dx01v2` (este repositório) | AWS | aplicação (construída sobre o `docs/CONTRATO.md`) | ver matriz de status |
| [`tx02v2`](https://github.com/maringelix/tx02v2) | Azure | infraestrutura (Terraform, AKS, PostgreSQL Flexible Server, Application Gateway for Containers) | veja a matriz de status dele |
| [`dx02v2`](https://github.com/maringelix/dx02v2) | Azure | aplicação (o mesmo app deste repositório) | veja a matriz de status dele |
| [`tx03v2`](https://github.com/maringelix/tx03v2) | GCP | infraestrutura (Terraform, GKE Autopilot, Cloud SQL, Cloud Armor) | veja a matriz de status dele |
| [`dx03v2`](https://github.com/maringelix/dx03v2) | GCP | aplicação (o mesmo app deste repositório) | veja a matriz de status dele |

## Matriz de status

| Capacidade | Status | Evidência |
|---|---|---|
| Lint, formatação e checagem de tipos (eslint, prettier, tsc para `api` e `web`) | `verificado no CI` | `make static` (`eslint`, `prettier`, `typecheck:*`); job `static` do CI |
| Dockerfiles, workflows e scripts (hadolint, actionlint, shellcheck) | `verificado no CI` | `make static` (`hadolint`, `actionlint`, `shellcheck`) |
| Manifests Kubernetes: render do kustomize + kubeconform estrito (local, aws, aws-https), asserções de contrato e de hardening, trivy config | `verificado no CI` | `make static` (`kubeconform`, `contract-app`, `trivy-config`) |
| Scan de segredos e políticas do repositório (sem identificadores reais, actions e imagens fixadas, regressões do v1) | `verificado no CI` | `make static` (`gitleaks`, `policy-*`, `repo-structure`, `version-consistency`) |
| Testes unitários + de integração da API contra um PostgreSQL 17 real (gate de cobertura: linhas >= 80 %, branches >= 70 %) | `verificado no CI` | `make test` (`test:api`); job `test` do CI |
| Testes da página com Testing Library + jsdom (gate de cobertura: linhas >= 70 %) | `verificado no CI` | `make test` (`test:web`); job `test` do CI |
| Imagens: build, usuário numérico não root, sem npm nem shell no runtime da API, gate do trivy HIGH/CRITICAL | `verificado no CI` | `make build`; job `images` do CI |
| Stack do compose (PostgreSQL → migrate → api → web em 127.0.0.1) + smoke test | `verificado localmente` | `scripts/dev-env.sh`, `scripts/compose-smoke.sh` (manual, fora do CI) |
| Ponta a ponta no kind: Pod Security `restricted`, smoke test pelo nginx, enforcement de NetworkPolicy | `verificado no CI` | `make e2e` (`scripts/e2e-kind.sh`); job `e2e` do CI |
| Deploy na AWS (push no ECR, EKS do tx01v2, ExternalSecrets, ALB + WAF, traces para o OpenTelemetry Collector do tx01v2 e o AWS X-Ray, smoke test pelo ALB) | `não executado em nuvem (v2)` | `.github/workflows/deploy-aws.yml`, `scripts/deploy-aws.sh`, `docs/RUNBOOK.md` |
| Configurações do repositório como código (ruleset, environment `lab`) | `verificado localmente` | `scripts/repo-guardrails.sh` aplicado; conferido com `gh api` em 2026-10-14 (`docs/PUBLICACAO.md`) |
| **O app na plataforma local completa do tx01v2** (kind + ECR, RDS, S3, load balancer e servidor git emulados): imagens no registry do lab, GitOps com Argo CD (Synced, Healthy, self-heal) | `verificado no CI` | `make e2e-platform` (`scripts/deploy-local.sh`, `scripts/e2e-platform.sh`, overlay `local-platform`) |
| HTTPS pelo load balancer emulado e um Gateway do Istio (cert-manager, CA do lab), smoke test de fora do mesh; TLS `verify-full` no banco | `verificado no CI` | `make e2e-platform` (sonda `smoke`) |
| Istio ambient: mTLS `STRICT`, `AuthorizationPolicy` por identidade (Gateway, web, Prometheus), NetworkPolicies com HBONE | `verificado no CI` | `contract-app` (`local-platform`); `make e2e-platform` (sonda `mesh`) |
| Observabilidade: ServiceMonitor, cinco regras de alerta testadas com promtool, dashboard do Grafana como código, logs no Loki | `verificado no CI` | `promtool-rules`; `make e2e-platform` (sondas `observability`) |
| Traces com OpenTelemetry: um trace no Tempo do Gateway do Istio até a consulta ao PostgreSQL (W3C trace context), `trace_id` nos logs do Loki, exemplars no histograma de latência | `verificado no CI` | testes da API (`telemetry`, `tracing`); `make e2e-platform` (sonda `tracing`) |
| Gatekeeper (o app é admitido pelas políticas do lab), relatórios do Trivy Operator das imagens do app, HPA 2-4 | `verificado no CI` | `make e2e-platform` |
| Rollout sem downtime: uma versão nova pelo GitOps, nenhuma requisição de um leitor falha durante o rolling update | `verificado no CI` | `make e2e-platform` (sonda `rollout`) |
| Ensaio de backup + restore do banco; experimentos de chaos com hipótese (um pod da API morto, leituras continuam; 200 ms entre a API e o PostgreSQL, as leituras passam e o trace mostra o atraso) | `verificado no CI` | `make e2e-platform` (sondas `backup`, `chaos`) |

As linhas `verificado no CI` rodam em todo pull request, em todo push para a `main` e toda semana
(jobs do CI na coluna Evidência); a linha do compose é verificada só localmente. A linha da AWS só
muda com uma issue `cloud_run_report` (data, região, commits, custo, saída do smoke test, sobras).

## Arquitetura

```mermaid
flowchart LR
  browser((Navegador)) -->|"/ e /api/ (mesma origem)"| web["web: nginx-unprivileged :8080<br/>SPA + cabeçalhos de segurança"]
  web -->|"/api/ → api:3000"| api["api: Express 5, Node.js 24<br/>distroless, não root"]
  api -->|"Pool pg, TLS verify-full na AWS"| db[("PostgreSQL 17")]
  migrate["migrate (mesma imagem)<br/>advisory lock"] --> db
  prom["Prometheus (namespace monitoring)"] -.->|":9464 /metrics"| api
```

- Local (compose) e kind: um proxy reverso (o nginx do web) na frente da API (`TRUST_PROXY_HOPS=1`).
- AWS: o ALB (com o WAF do tx01v2) manda `/api` para a API e `/` para o web; os segredos vêm do
  Secrets Manager pelo External Secrets; namespace, IAM e RDS são do tx01v2.
- Decisões de design, diagramas por ambiente e a tabela v1 → v2: [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

## Início rápido (grátis, local)

Você precisa de Docker e do devcontainer ou de Linux/WSL 2 com bash >= 4.4, Node.js 24 (`.nvmrc`),
curl, unzip, xz, git e make.

```bash
git clone https://github.com/maringelix/dx01v2.git && cd dx01v2
make tools                     # ferramentas fixadas em .tools/, SHA256 conferido
HARNESS_STRICT=1 make verify   # checks estáticos + testes (sobe um PostgreSQL descartável no Docker)
make build                     # as duas imagens + gate do trivy
make e2e                       # cluster kind dx01v2-e2e: deploy, smoke test, sondas de NetworkPolicy
```

Rodar o app:

```bash
scripts/dev-env.sh                                  # .env com segredos aleatórios (ignorado pelo git)
docker compose -p dx01v2-dev up -d --build --wait   # http://127.0.0.1:8080
scripts/compose-smoke.sh                            # o mesmo smoke test do kind e da AWS
docker compose -p dx01v2-dev down -v
```

No Windows ou macOS, abra a pasta no devcontainer (`.devcontainer/devcontainer.json`, com
Docker-in-Docker); ele roda `make tools` sozinho. Nada aqui toca a AWS. Referência da API com
exemplos em curl: [docs/API.md](docs/API.md).

## Caminho em nuvem (custa dinheiro)

**Custo primeiro:** o app roda no lab do tx01v2, cerca de US$0,26–0,32 por hora em us-east-1 com os
padrões, incluindo o ALB que este app cria (preços de tabela de referência, ver o
[documento de custos do tx01v2](https://github.com/maringelix/tx01v2/blob/main/docs/CUSTOS.md)). Um
lab esquecido custa mais de US$40 por semana. Use uma conta AWS dedicada e destrua no mesmo dia.

Siga o [docs/RUNBOOK.md](docs/RUNBOOK.md): bootstrap/apply/plataforma do tx01v2 → variáveis do
GitHub do dx01v2 → workflow `deploy-aws` (ou `scripts/deploy-aws.sh`) → smoke test pelo ALB →
destroy do tx01v2 + checagem de sobras → issue `cloud_run_report`.

## Harness

| Alvo | O que roda | Quando |
|---|---|---|
| `make help` | lista os alvos | a qualquer momento |
| `make tools` | `scripts/install-tools.sh`: trivy 0.75.0, hadolint 2.15.1, actionlint 1.7.12, shellcheck 0.11.0, kubeconform 0.8.0, gitleaks 8.30.1, kind 0.33.0, kubectl 1.36.5 | uma vez, e depois de atualizar uma ferramenta |
| `make static` | `scripts/harness.sh static` | antes de cada push |
| `make test` | `scripts/harness.sh test` (PostgreSQL 17 real: `DB_*` ou um container descartável) | antes de cada push |
| `make verify` | static + test | antes de cada PR |
| `make build` | `scripts/harness.sh build`: build npm, imagens, política das imagens, gate do trivy | quando código, Dockerfiles ou dependências mudam |
| `make e2e` | `scripts/harness.sh e2e`: cluster kind, smoke test, sondas de NetworkPolicy | quando manifests, imagens ou o app mudam |
| `make e2e-platform` | `scripts/harness.sh platform`: o app na plataforma local completa do tx01v2 (clona o tx01v2 em `deploy/local/tx01v2.ref`), sempre destruída no fim (job `e2e-platform` do CI) | mudanças em manifests, imagens ou no app; precisa de Docker com 8 GB |
| `make all` | todos os estágios | antes de um merge importante |
| `make clean` | remove `.tools/`, saída de build, cobertura, `node_modules` e dados temporários | — |

`scripts/harness.sh list` mostra todos os checks. Detalhes: [docs/HARNESS.md](docs/HARNESS.md).

## Documentação

| Documento | Conteúdo |
|---|---|
| [FORK.md](FORK.md) | fork do lab (em inglês): o que o GitHub não copia, o lab local, a sua conta de nuvem |
| [docs/ARQUITETURA.md](docs/ARQUITETURA.md) | diagramas (local, kind, AWS), decisões, v1 → v2 |
| [docs/API.md](docs/API.md) | endpoints, erros, exemplos em curl |
| [docs/CONTRATO.md](docs/CONTRATO.md) | contrato tx01v2 ⇄ dx01v2 v2 (lado do app; fonte da verdade no tx01v2) |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | desenvolvimento local, compose, e2e no kind, deploy na AWS |
| [docs/GUARDRAILS.md](docs/GUARDRAILS.md) | regras, aplicação, exceções, limites |
| [docs/HARNESS.md](docs/HARNESS.md) | checks, modo estrito, problemas comuns |
| [docs/SUSTENTACAO.md](docs/SUSTENTACAO.md) | rotinas, calendário de fim de suporte, procedimentos de atualização |
| [docs/PUBLICACAO.md](docs/PUBLICACAO.md) | checklist para tornar o repositório público |

## Contribuindo

Leia o [CONTRIBUTING.md](CONTRIBUTING.md) e o [AGENTS.md](AGENTS.md) (também para humanos).
Vulnerabilidades: [SECURITY.md](SECURITY.md).

## Licença

[MIT](LICENSE) — Copyright (c) 2025-2026 Bruno Maringeli.
