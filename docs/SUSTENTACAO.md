# Sustentação do dx01v2

Como manter o repositório saudável sem conta na nuvem: rotinas, calendário de fim de suporte e
procedimentos passo a passo. Datas e versões verificadas em 2026-10-10.

## 1. Objetivo e escopo

Cobre o código do app (API, página, migrações), as dependências npm, as imagens base, os manifests,
os scripts e workflows, as ferramentas do harness e as rodadas opcionais em nuvem. A infraestrutura
(EKS, RDS, WAF, camada de plataforma) é do `tx01v2`, com a sustentação descrita lá.

## 2. Estado atual

- Estágios `static`, `test`, `build` e `e2e` `verificado no CI` (jobs `static`, `test`, `images` e
  `e2e`) e localmente em containers Linux.
- Deploy na AWS: `não executado em nuvem (v2)`.
- Contrato com o tx01v2: versão 1 (`docs/CONTRATO.md`).
- Exceções de scanner: nenhuma (`.trivyignore.yaml` vazio).

## 3. Rotinas

| Quando | O quê | Como |
|---|---|---|
| Semanal (automático) | CI agendado (segunda 06:00 UTC) roda todos os jobs, inclusive o trivy das imagens | Falhou? Seção 6. Causas típicas: CVE novo numa imagem base ou dependência, URL que mudou, rede |
| Mensal | PRs do Dependabot (npm, Docker, actions, pre-commit) | Playbook "Dependency updater" do `AGENTS.md`; um PR por grupo, CI verde antes do merge |
| Trimestral | Ferramentas do harness, digests das imagens (incluindo PostgreSQL, kind e devcontainer), versões de plataforma (Node.js, nginx, Kubernetes), schemas do kubeconform, ignores perto de vencer; paridade do app com o `dx02v2` e o `dx03v2` (`api/` e `web/` iguais, fora os nomes; `e2e/` só difere no que a borda muda) | Seções 4 e 5; registre no CHANGELOG |
| Por rodada em nuvem: antes | Ler o custo no tx01v2 (`docs/CUSTOS.md` de lá), CI verde no commit, tx01v2 aplicado e com a plataforma instalada, variáveis do GitHub | `docs/RUNBOOK.md` |
| Por rodada em nuvem: durante | Anotar horários, saída do smoke test e problemas; não deixar a rodada aberta de um dia para o outro | `docs/RUNBOOK.md` |
| Por rodada em nuvem: depois | destroy do tx01v2, `scripts/leftovers.sh` limpo, issue `cloud_run_report`, matriz de status só com evidência | `docs/RUNBOOK.md`, seção 7 |

## 4. Calendário de fim de suporte

| Componente | Versão | Fim do suporte | Fonte | Ação |
|---|---|---|---|---|
| Node.js | 24 (`.nvmrc`; imagens com 24.21.0) | 2028-04-30 | [calendário do Node.js](https://github.com/nodejs/Release#release-schedule) | Migrar para o 26 (seção 5.3) com folga, depois de ele virar LTS |
| Node.js | 26 | LTS a partir de 2026-10-28; fim em 2029-04-30 | idem | Candidato na primeira revisão trimestral depois de 2026-10-28 (imagens distroless e alpine precisam existir) |
| TypeScript | 6.0.3 | sem data publicada | [typescript-eslint: versões suportadas](https://typescript-eslint.io/users/dependency-versions) | Manter dentro de `>=4.8.4 <6.1.0` (typescript-eslint 8.71); o TypeScript 7 só entra quando o typescript-eslint suportar. O `dependabot.yml` ignora minors e majors do `typescript` (só patches chegam); revisar a regra na revisão trimestral |
| React / Vite / Vitest | 19.3 / 8.3 / 5.0 | sem calendário publicado; correções vão para a major atual | react.dev, vite.dev, vitest.dev | Majors chegam como PRs individuais do Dependabot; ler o guia de migração |
| Express | 5.3 | linha 5.x ativa | [política de suporte do Express](https://expressjs.com/en/support/) | Acompanhar pelo Dependabot |
| PostgreSQL | 17 (`postgres:17-alpine`, imagem com 17.11) | 2029-11-08 (comunidade) | [versionamento do PostgreSQL](https://www.postgresql.org/support/versioning/) | A major segue o RDS do tx01v2 (contrato); trocar compose, CI, kind e harness juntos |
| nginx (web) | 1.30 estável (`nginxinc/nginx-unprivileged:1.30.5-alpine3.24-slim`) | a linha estável recebe correções até a próxima estável (1.32, prevista para ~abril de 2027) | [nginx.org](https://nginx.org/en/download.html) | Mudar para a nova linha estável (minor par) na revisão trimestral seguinte ao lançamento. O `dependabot.yml` ignora minors do `nginx-unprivileged`, que levariam à linha mainline (ímpar) |
| Alpine (build e runtime do web) | 3.24 | ~2028-05 (cada versão tem ~2 anos de suporte) | [releases do Alpine](https://alpinelinux.org/releases/) | Acompanha os digests do node e do nginx-unprivileged |
| Distroless (runtime da API) | `nodejs24-debian13:nonroot` | segue o Debian 13 (segurança até ~2028-08) e o Node.js 24 | [distroless](https://github.com/GoogleContainerTools/distroless) | A variante `debian12` parou no Node.js 24.14.0 (verificado em 2026-10-10): não voltar para ela |
| Kubernetes (kind, kubectl, schemas) | 1.36 (nó `v1.36.4`, kubectl 1.36.5) | upstream: ~2027-06 (cerca de 14 meses após o lançamento); EKS padrão: 2027-08-02 | [releases do Kubernetes](https://kubernetes.io/releases/), [calendário do EKS](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) | Mudar junto com o tx01v2 (mudança de minor é mudança de contrato), seção 5.5 |
| kind | v0.33.0 (padrão do kind: Kubernetes 1.37.0) | sem política de fim de suporte | [releases do kind](https://github.com/kubernetes-sigs/kind/releases) | Trimestral; a imagem do nó vem das notas da release, por digest |
| Runners e devcontainer | Ubuntu 24.04 LTS (runners), Debian 13 (`javascript-node:24-trixie`) | Ubuntu 24.04: 2029-04 | ubuntu.com, debian.org | Trocar antes do fim |
| Exceções do trivy | nenhuma | — | `.trivyignore.yaml` | Seção 5.9 quando houver |

## 5. Procedimentos

### 5.1 Ferramenta do harness (trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind, kubectl)

```bash
scripts/update-tool-checksums.sh trivy 0.76.0   # baixa o arquivo de checksums oficial da release
make tools && HARNESS_STRICT=1 make verify build
git diff tools/                                 # versions.env + checksums.txt
```

O script lê o arquivo de checksums publicado na release exata (shellcheck não publica: o script baixa
os três artefatos e calcula o SHA256). Leia as release notes antes; para o trivy, achados novos podem
aparecer só com a ferramenta nova (o harness usa as regras embutidas, `--skip-check-update`).

### 5.2 Dependências npm

PRs do Dependabot: confira o CI e as release notes. À mão, sempre com versão exata e o lock junto:

```bash
npm install --save-exact --workspace api express@5.3.1   # ou --workspace web, ou sem workspace (raiz)
HARNESS_STRICT=1 make verify build && make e2e
```

Restrições: `typescript` dentro da faixa do `typescript-eslint` (o Dependabot ignora minors e majors
dele); `@types/node` na major do Node.js de `.nvmrc` (o Dependabot ignora majors dele);
`@vitejs/plugin-react` compatível com a major do Vite. Um PR do Dependabot que quebra uma dessas
restrições falha no `npm ci` (ERESOLVE) e deve ser fechado com um comentário, nunca forçado com
`--legacy-peer-deps`.

### 5.3 Major do Node.js (por exemplo 24 → 26)

1. `.nvmrc` e `engines.node` dos três `package.json` (`>=26 <27`); `@types/node` 26.
2. Imagem de build `node:26-alpine<versão>` nos dois Dockerfiles (mesmo digest) e runtime
   `gcr.io/distroless/nodejs26-debian13:nonroot` na API (o healthcheck do compose usa `/nodejs/bin/node`).
3. Devcontainer `javascript-node:26-*` por digest.
4. `HARNESS_STRICT=1 make verify build && make e2e`; o check `version-consistency` acusa o que faltar.
   O CI usa `.nvmrc` (`actions/setup-node`).

### 5.4 Digests de imagens

```bash
docker buildx imagetools inspect node:24-alpine3.24              # e nginxinc/nginx-unprivileged:1.30-alpine-slim
docker buildx imagetools inspect gcr.io/distroless/nodejs24-debian13:nonroot
docker buildx imagetools inspect postgres:17-alpine
docker buildx imagetools inspect mcr.microsoft.com/devcontainers/javascript-node:24-trixie
```

Use o digest do índice multiplataforma e atualize o comentário com a tag e a data. O digest do
PostgreSQL aparece em `compose.yaml`, `.github/workflows/ci.yml`,
`deploy/k8s/overlays/local/postgres.yaml` e `scripts/harness.sh` (o `version-consistency` exige o
mesmo nos quatro). Confira a versão real dentro da imagem (por exemplo
`docker run --rm --entrypoint node <imagem> --version`), porque tags podem parar de ser reconstruídas.

### 5.5 Kubernetes e kind

1. kind: `scripts/update-tool-checksums.sh kind <versão>`; a imagem do nó (`kind/kind-config.yaml`)
   vem das notas da release, sempre com `@sha256`.
2. kubectl na mesma minor do nó: `scripts/update-tool-checksums.sh kubectl <versão>`.
3. `K8S_SCHEMA_KUBERNETES_VERSION` em `scripts/harness.sh` (e um `K8S_SCHEMA_REF` que tenha essa
   versão). O `version-consistency` exige a mesma minor no nó, no kubectl e nos schemas.
4. A minor do EKS é do tx01v2 (contrato): mude os dois repositórios juntos.

### 5.6 Gate do trivy vermelho (imagens)

1. Leia a tabela do check `trivy-image:*` (pacote, versão instalada, versão corrigida).
2. Pacote do sistema (Alpine/Debian): atualize o digest da imagem base (5.4); se a correção ainda não
   chegou à imagem, espere a reconstrução (normalmente dias) ou troque de tag.
3. Pacote npm: atualize a dependência (5.2); se a vulnerável for transitiva, um `overrides` no
   `package.json` da raiz com versão exata, explicado no PR.
4. Sem correção aplicável e risco aceito: exceção temporária (seção 5.9 e `docs/GUARDRAILS.md`),
   nunca `--severity` mais baixo nem o gate desligado.

### 5.7 Schemas do kubeconform

`K8S_SCHEMA_REF` (yannh/kubernetes-json-schema) e `CRD_SCHEMA_REF` (datreeio/CRDs-catalog) em
`scripts/harness.sh` apontam para commits fixos:
`gh api 'repos/datreeio/CRDs-catalog/commits?path=external-secrets.io/externalsecret_v1.json&per_page=1'`.

### 5.8 Actions

Fora do Dependabot: `gh api repos/<o>/<r>/git/ref/tags/<tag>`; se `object.type == "tag"`, siga
`gh api repos/<o>/<r>/git/tags/<sha>`; use o SHA do commit com `# vX.Y.Z`.

### 5.9 Revisão das exceções do trivy

Para cada entrada de `.trivyignore.yaml` perto do `expired_at`: o motivo ainda vale? Se sim, renove
por até ~7 meses com a justificativa atualizada; se não, corrija e remova a entrada.

## 6. Resposta a problemas

| Situação | Primeiros passos |
|---|---|
| CI vermelho | Leia o primeiro `FAIL` (o log do check vem logo abaixo). Corrija no código; nunca enfraqueça o check. Reproduza com `HARNESS_STRICT=1 make verify build` e `make e2e` |
| Vulnerabilidade | Gate do trivy: 5.6. Alerta do Dependabot ou advisory: atualize por PR. Reporte privado: `SECURITY.md` |
| Credencial exposta | Local: `scripts/dev-env.sh --force` e `docker compose -p dx01v2-dev down -v`. AWS: gire o valor no Secrets Manager (tx01v2), espere o ESO sincronizar (até 1 h) e `kubectl -n dx01v2 rollout restart deployment/api`. GitHub: revogue o token. Reescrever histórico é decisão do mantenedor |
| Alerta de custo | Siga o tx01v2 (`scripts/leftovers.sh`, destroy); o app só cria o ALB pelo Ingress |
| Sobras após o destroy | Runbook do tx01v2; registre no `cloud_run_report` |

## 7. Registro de execuções em nuvem

Toda rodada gera uma issue com o template `cloud_run_report` (data, região, commits, passos, duração,
custo observado, saída do smoke test, problemas, sobras). A matriz de status do README só muda com
essa evidência.

## 8. Responsáveis

Mantenedor: @maringelix (decisões, merges, rodadas em nuvem). Agentes de IA seguem o `AGENTS.md`.
