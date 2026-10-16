# Runbook do dx01v2

Passo a passo para desenvolver e testar o app localmente (npm, compose, kind) e para publicá-lo no
cluster EKS do tx01v2. O caminho local é grátis e `verificado localmente`; o deploy na AWS nunca foi
executado (`não executado em nuvem (v2)`): você será a primeira evidência.

## 1. Pré-requisitos locais

- Docker e o devcontainer (`.devcontainer/devcontainer.json`, com Docker-in-Docker), ou Linux/WSL 2
  com Docker, bash >= 4.4, Node.js 24 (`.nvmrc`), curl, unzip, xz, git e make.
- `make tools` instala trivy, hadolint, actionlint, shellcheck, kubeconform, gitleaks, kind e kubectl
  fixados em `.tools/`.
- Portas locais: 8080 (compose, `WEB_PORT`, só 127.0.0.1), 15432 (PostgreSQL de desenvolvimento, só
  127.0.0.1), 5173 (Vite, só 127.0.0.1) e 3000/9464 (API em desenvolvimento, todas as interfaces).

## 2. Desenvolvimento com npm workspaces

Um único `package-lock.json` na raiz; os workspaces são `api` e `web`.

```bash
npm ci
# PostgreSQL 17 descartável em 127.0.0.1:15432, senha e token aleatórios só nesta sessão do shell
export DB_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
export ADMIN_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
docker run -d --rm --name dx01v2-dev-pg -p 127.0.0.1:15432:5432 \
  -e POSTGRES_DB=dx01v2 -e POSTGRES_USER=dx01v2 -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24
export DB_HOST=127.0.0.1 DB_PORT=15432 DB_NAME=dx01v2 DB_USER=dx01v2
node api/src/migrate.ts            # migrações (o Node.js 24 executa TypeScript direto)
npm run dev --workspace api        # API na porta 3000, métricas na 9464, recarrega ao salvar
npm run dev --workspace web        # outro terminal: Vite em http://127.0.0.1:5173 (/api → :3000)
docker rm -f dx01v2-dev-pg         # ao terminar
```

Comandos úteis: `npm run lint`, `npm run typecheck`, `npm run format`, `npm run build`; testes:
`npm run test:coverage --workspace web` e, para a API, que usa o banco de `DB_*` e **apaga e recria
as tabelas**, um banco cujo nome termina em `_test` (os testes recusam qualquer outro nome):

```bash
docker exec dx01v2-dev-pg createdb -U dx01v2 dx01v2_test
DB_NAME=dx01v2_test npm run test:coverage --workspace api
```

O gate completo é `HARNESS_STRICT=1 make verify`: sem `DB_HOST` ele sobe um PostgreSQL descartável;
com `DB_*` exportadas, usa esse banco e recusa um `DB_NAME` que não termine em `_test` (neste shell:
`env -u DB_HOST HARNESS_STRICT=1 make verify`).

## 3. Stack do compose (projeto `dx01v2-dev`)

```bash
scripts/dev-env.sh                                  # .env com DB_PASSWORD e ADMIN_TOKEN aleatórios (600)
docker compose -p dx01v2-dev up -d --build --wait   # db → migrate → api → web
scripts/compose-smoke.sh                            # e2e/smoke.mjs contra http://127.0.0.1:8080
docker compose -p dx01v2-dev down -v                # remove containers, rede e volume do banco
```

- Só o web é publicado (`127.0.0.1:${WEB_PORT:-8080}`); a API e o banco ficam em redes internas.
- Containers com root filesystem somente leitura, `cap_drop: [ALL]` e `no-new-privileges`.
- O modo admin da página aceita o `ADMIN_TOKEN` do `.env` (fica só na memória da aba).
- Trocar os segredos: `scripts/dev-env.sh --force` e depois `down -v` (o volume guarda a senha antiga).
- Outra porta: `WEB_PORT=18080 scripts/dev-env.sh --force`.

## 4. Ponta a ponta no kind (`make e2e`)

```bash
make tools
make e2e                         # cria dx01v2-e2e, testa e apaga o cluster
KEEP_CLUSTER=1 make e2e          # mantém o cluster para investigar
kind get kubeconfig --name dx01v2-e2e > /tmp/dx01v2-e2e.kubeconfig
KUBECONFIG=/tmp/dx01v2-e2e.kubeconfig kubectl -n dx01v2 get pods,svc,networkpolicy
kind delete cluster --name dx01v2-e2e
```

O script (`scripts/e2e-kind.sh`) constrói as imagens `dx01v2-api:e2e` e `dx01v2-web:e2e`, cria o
cluster a partir de `kind/kind-config.yaml` (nó v1.36.4 por digest), carrega as imagens, cria os
Secrets com valores aleatórios, aplica `deploy/k8s/overlays/local`, espera os rollouts, prova que o
namespace rejeita um pod privilegiado, roda o smoke test por um port-forward para `svc/web` e testa
as NetworkPolicies com pods descartáveis. Em caso de falha, os diagnósticos ficam em
`$TMPDIR/dx01v2-harness/e2e-diagnostics`.

## 5. AWS: pré-requisitos

> **Custo**: o app roda no lab do tx01v2, cerca de US$0,26–0,32 por hora em us-east-1 com os padrões,
> incluindo o ALB criado pelo Ingress deste app (ver `docs/CUSTOS.md` do tx01v2). Destrua no mesmo dia.

1. tx01v2: bootstrap, apply e plataforma concluídos (runbook do tx01v2). O ARN do papel
   `dx01v2-gha-deploy` (output `deploy_role_arn` do bootstrap) precisa estar em
   `LAB_APP_DEPLOYER_PRINCIPAL_ARNS` do tx01v2 antes do apply: é isso que cria a access entry no
   grupo `dx01v2-deployers`. Para deploy a partir de um laptop, inclua também o ARN do seu papel.
2. Repositório dx01v2 público com `scripts/repo-guardrails.sh` aplicado (environment `lab` com
   revisor obrigatório e só `main`; o `sub` OIDC aceito é `repo:<owner>/dx01v2:environment:lab`).
3. Variáveis do GitHub (seção 6).

## 6. Variáveis do GitHub

Settings > Secrets and variables > Actions > **Variables** (aparecem nos logs: nada privado).

| Variável | Exemplo | Uso |
|---|---|---|
| `AWS_REGION` | `us-east-1` | região do lab; precisa ser igual a `/tx01v2/lab/region` |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/dx01v2-gha-deploy` | papel assumido por OIDC |
| `ALB_CERTIFICATE_ARN` | `arn:aws:acm:us-east-1:<ACCOUNT_ID>:certificate/<ID>` | opcional: liga HTTPS (overlay `aws-https`, HTTP 80 redireciona para 443) |
| `SMOKE_BASE_URL` | `https://app.example.com` | obrigatória com `ALB_CERTIFICATE_ARN`: um nome DNS do certificado com CNAME para o ALB (crie o registro quando o hostname do ALB aparecer) |

## 7. Deploy

No Actions, abra `deploy-aws`, escolha a branch `main` e aprove o environment `lab`. O workflow usa
GitOps e exige o perfil `full` do tx01v2, a Application `dx01v2` no Argo CD e permissão para publicar
`gitops/aws`. Se o cluster não usa Argo CD, execute o script de um laptop com `DEPLOY_MODE=push`.

O job roda `scripts/deploy-aws.sh`, que:

1. lê os 10 parâmetros do SSM e confere região, cluster, nomes dos segredos, ClusterSecretStore e repositórios ECR;
2. constrói `linux/amd64` e publica `dx01v2/api:<sha>` e `dx01v2/web:<sha>`; tags existentes são reutilizadas e nunca sobrescritas;
3. obtém kubeconfig temporário, confere o acesso ao namespace e, no modo GitOps, o direito de atualizar a Application `dx01v2`; cria o ConfigMap `rds-ca`;
4. renderiza e valida o overlay `aws` ou `aws-https`. No workflow, configura os valores reais na Application, publica o commit do app com `params.env` de exemplo na branch `gitops/aws` e pede refresh ao Argo CD. No uso local com `DEPLOY_MODE=push`, aplica o overlay com `kubectl apply -k`;
5. no modo GitOps, espera a Application estar `Synced` e `Healthy` no commit publicado; depois espera ExternalSecrets e rollouts e confere as imagens SHA nos Deployments;
6. espera o hostname do ALB e roda `e2e/smoke.mjs`. Sem certificado, o ALB só fala HTTP e o token de admin não é lido nem enviado; com HTTPS, o smoke test faz o `DELETE` autorizado.

De um laptop, configure as credenciais AWS e a autenticação Git para publicar a branch GitOps:

    make tools
    AWS_REGION=us-east-1 scripts/deploy-aws.sh

Sem Argo CD, use `DEPLOY_MODE=push AWS_REGION=us-east-1 scripts/deploy-aws.sh`.

## 8. Conferir

```bash
aws eks update-kubeconfig --name tx01v2-lab --region us-east-1 --kubeconfig ~/.kube/tx01v2-lab.kubeconfig
export KUBECONFIG=~/.kube/tx01v2-lab.kubeconfig   # só neste terminal; o ~/.kube/config não muda
kubectl -n dx01v2 get pods,ingress,externalsecrets,hpa
curl -fsS "http://<ALB_HOSTNAME>/api/info"
```

Traces (contrato v2): depois de algumas requisições, o serviço `dx01v2-api` aparece no X-Ray (console
do CloudWatch, traces) da região do lab. O caminho é API → `opentelemetry-collector.observability`
(OTLP/HTTP, porta 4318) → X-Ray; o Collector e a permissão de escrita são do tx01v2.

## 9. Desligar

O teardown é o do tx01v2: o workflow `terraform-destroy` roda `platform/uninstall.sh`, que apaga
todos os Ingresses (e assim o ALB) antes do `terraform destroy`, e termina com `scripts/leftovers.sh`.
Para tirar só o ALB do app e manter o cluster: `kubectl -n dx01v2 delete ingress dx01v2`.

## 10. Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `the SSM parameter ... is missing` | tx01v2 não aplicado nesta região | aplique o tx01v2 ou corrija `AWS_REGION` |
| `this principal cannot deploy to namespace dx01v2` | sem access entry no grupo `dx01v2-deployers` ou plataforma não instalada | adicione o ARN a `LAB_APP_DEPLOYER_PRINCIPAL_ARNS` e rode o apply e o workflow `platform` do tx01v2 |
| ExternalSecret não fica `Ready` | ClusterSecretStore ou segredo ausente | `kubectl -n dx01v2 describe externalsecret db-credentials`; confira a plataforma do tx01v2 |
| initContainer `migrate` falha com erro de TLS | ConfigMap `rds-ca` ausente ou região errada | o script recria o ConfigMap; confira `DB_SSL_CA_FILE` e o bundle da região |
| Ingress sem endereço | AWS Load Balancer Controller ou tags de subnet | `kubectl -n dx01v2 describe ingress dx01v2` (eventos do controller) |
| Smoke test com 403 em tudo | regra do WAF (reputação de IP, limite por IP) | logs do WAF (`aws-waf-logs-tx01v2-lab`) |
| `tag invalid ... already exists` no push | tag imutável já publicada | a imagem daquele commit já existe: o script só a reutiliza quando a consulta ao ECR funciona |
| Nenhum trace no X-Ray | Collector ausente (plataforma antiga do tx01v2, contrato v1) ou sem a permissão do X-Ray | `kubectl -n observability get pods`; logs do Collector (`kubectl -n observability logs deployment/opentelemetry-collector`); a API nunca falha por isso: os spans só se perdem |

## 11. Registro

Abra uma issue com o template **Cloud run report**: data, região, commits do dx01v2/tx01v2, passos,
duração, custo observado, saída do smoke test, problemas e a saída (redigida) do
`scripts/leftovers.sh` do tx01v2.
