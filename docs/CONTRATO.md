# Contrato tx01v2 <-> dx01v2 — versão 4 (2026-10-16)

Versão 4: a camada `full` integra o app ao Istio ambient e ao Gatekeeper e registra no Argo CD a
revisão `gitops/aws`; o grupo `dx01v2-deployers` pode pedir refresh da Application `dx01v2` (R4.1/R4.4).
A versão 3 (2026-10-15) fixou o subject OIDC aos IDs imutáveis e restringiu deploy à `main`; a versão
2 (2026-10-14) adicionou traces do app pelo Collector ao AWS X-Ray.

Interface entre a infraestrutura (`tx01v2`) e a aplicação (este repositório), na parte que o app usa.
A fonte da verdade é o
[`docs/CONTRATO.md` do tx01v2](https://github.com/maringelix/tx01v2/blob/main/docs/CONTRATO.md):
em caso de divergência, vale aquele arquivo. Qualquer mudança exige PRs coordenados nos dois
repositórios e incremento da versão.

## Como o contrato é verificado aqui

| O quê | Onde | Status |
|---|---|---|
| Nomes de Services, portas, probes, Secrets, ConfigMap, Ingress (classe, anotações, rotas, health checks), ExternalSecrets, HPA, NetworkPolicies, só tipos que a Role `dx01v2-deployer` pode escrever | check `contract-app` (`scripts/check-manifests.mjs` sobre os overlays renderizados) | `verificado localmente` |
| Endpoint OTLP da versão 2 no ConfigMap da API e NetworkPolicy só até o Collector (namespace `observability`, porta 4318) | check `contract-app` | `verificado localmente` |
| Manifests válidos para Kubernetes 1.36 e para o CRD `ExternalSecret` (`external-secrets.io/v1`) | check `kubeconform` (estrito) | `verificado localmente` |
| O deploy lê exatamente os 10 parâmetros SSM abaixo, com o prefixo `/tx01v2/lab`, e cria o `rds-ca` a partir do bundle oficial | check `contract-app` (greps em `scripts/deploy-aws.sh`) | `verificado localmente` |
| Formatos dos valores vindos do SSM (URLs do ECR, ARN do WAF, CIDR da VPC, ARN do ACM) | `k8s_validate_params` em `scripts/lib/k8s.sh` (renderização com `params.example.env`) | `verificado localmente` |
| Valores fixos (`cluster-name`, nomes dos segredos, ClusterSecretStore) iguais aos do SSM | `scripts/deploy-aws.sh` falha antes de aplicar qualquer coisa | `não executado em nuvem (v2)` |
| Comportamento real na AWS | `docs/RUNBOOK.md` | `não executado em nuvem (v2)` |

## Identificadores

| Item | Valor |
|---|---|
| Região AWS | variável Terraform `aws_region` do tx01v2, padrão `us-east-1` (variável `AWS_REGION` do GitHub aqui) |
| Prefixo de nomes | `tx01v2-lab` |
| Cluster EKS | `tx01v2-lab`, Kubernetes `1.36` (suporte padrão do EKS até 2027-08-02) |
| Namespace do app | `dx01v2` — criado pela camada de plataforma do tx01v2 com os labels `pod-security.kubernetes.io/enforce=restricted`, `pod-security.kubernetes.io/enforce-version=latest`, `elbv2.k8s.aws/pod-readiness-gate-inject=enabled`. Os overlays `aws*` não criam o namespace; o overlay `local` cria um equivalente para o kind |
| Grupo Kubernetes do deployer | `dx01v2-deployers`, ligado no namespace `dx01v2` (RoleBinding `dx01v2-deployers`) à Role `dx01v2-deployer` |
| Repositórios ECR | `dx01v2/api`, `dx01v2/web` — tags IMMUTABLE, scan on push; imagens com a tag do SHA git completo (40 caracteres) do dx01v2 |
| Papel OIDC do deploy | `dx01v2-gha-deploy` (criado pelo bootstrap do tx01v2) |
| Traces (OpenTelemetry) | `http://opentelemetry-collector.observability.svc:4318` (OTLP/HTTP; `OTEL_EXPORTER_OTLP_ENDPOINT` do componente `aws`). O Collector é instalado pela camada de plataforma do tx01v2 e grava os spans no AWS X-Ray da região do lab; o app não recebe nenhuma permissão da AWS para isso |

Regras da Role `dx01v2-deployer` (namespace `dx01v2`), que limitam o que os overlays `aws*` podem
conter (o check `contract-app` recusa qualquer outro tipo):

- `apps`: deployments → get, list, watch, create, update, patch, delete; replicasets → get, list, watch
- core: services, configmaps, serviceaccounts → get, list, watch, create, update, patch, delete;
  pods, pods/log, events, endpoints → get, list, watch; secrets → get, list, watch (o ESO escreve
  os segredos; o deployer nunca os escreve)
- `networking.k8s.io`: ingresses, networkpolicies → CRUD completo
- `autoscaling`: horizontalpodautoscalers → CRUD completo; `policy`: poddisruptionbudgets → CRUD completo
- `external-secrets.io`: externalsecrets → CRUD completo

Com o perfil `full` do `tx01v2`, o Argo CD é o dono dos manifests do app. O deploy configura o caminho,
as imagens e os valores reais em `spec.source.kustomize` da Application `dx01v2` no namespace `argocd`;
em seguida, publica o commit do app e `params.env` copiado do exemplo na branch `gitops/aws` e pede
refresh ao Argo CD. O app pai ignora somente `spec.source.path` e `spec.source.kustomize` dessa
Application e usa `RespectIgnoreDifferences=true`. Para um cluster sem Argo CD, selecione `push` e o
script aplica diretamente o overlay. A branch pública não recebe IDs reais da conta ou do projeto.

## Confiança OIDC do GitHub

| Papel | `sub` permitido (StringEquals, audience `sts.amazonaws.com`) |
|---|---|
| `dx01v2-gha-deploy` | `repo:<owner>@<owner id>/dx01v2@<repo id>:environment:lab` (dono e IDs configuráveis no tx01v2: `github_owner`, `github_owner_id`, `dx01v2_repository_id`, sem padrão) |

É o `sub` imutável do GitHub, o dos repositórios criados depois de 2026-07-15 (um fork também): leva o ID
numérico do dono e o do repositório, então um nome de conta apagado e registrado de novo não herda o
lab. O environment `lab` só implanta a partir de `main`.

Por isso o job do `deploy-aws.yml` usa `environment: lab` (o check `policy-workflows` exige).
Permissões de `dx01v2-gha-deploy`: `ecr:GetAuthorizationToken` em `*`; push/pull apenas nos dois
repositórios ECR (`BatchCheckLayerAvailability`, `BatchGetImage`, `CompleteLayerUpload`,
`GetDownloadUrlForLayer`, `InitiateLayerUpload`, `PutImage`, `UploadLayerPart`); `eks:DescribeCluster`
no cluster; `ssm:GetParameter`, `ssm:GetParameters`, `ssm:GetParametersByPath` em
`parameter/tx01v2/lab/*`. Acesso Kubernetes: access entry do EKS (tipo `STANDARD`,
`kubernetes_groups = ["dx01v2-deployers"]`) para cada ARN em `app_deployer_principal_arns` do tx01v2.

## Parâmetros SSM (tipo String, escritos pelo root do lab do tx01v2), prefixo `/tx01v2/lab/`

| Nome | Valor | Uso no dx01v2 |
|---|---|---|
| `region` | região AWS | conferido contra `AWS_REGION` |
| `cluster-name` | `tx01v2-lab` | `aws eks update-kubeconfig` |
| `vpc-id` | ID da VPC | lido e conferido (presença) |
| `vpc-cidr` | CIDR da VPC | NetworkPolicies ALB → pods e API → RDS (`VPC_CIDR`) |
| `ecr/api-url` | URL do repositório `dx01v2/api` | imagem da API (`API_IMAGE`) |
| `ecr/web-url` | URL do repositório `dx01v2/web` | imagem do web (`WEB_IMAGE`) |
| `waf/acl-arn` | ARN do web ACL WAFv2 REGIONAL | anotação `alb.ingress.kubernetes.io/wafv2-acl-arn` (`WAF_ACL_ARN`) |
| `db/secret-name` | `tx01v2-lab/db/app` | conferido contra o ExternalSecret `db-credentials` |
| `app/admin-token-secret-name` | `tx01v2-lab/app/admin-token` | conferido contra o ExternalSecret `app-secrets` |
| `eso/cluster-secret-store` | `aws-secrets-manager` | conferido contra o `secretStoreRef` dos ExternalSecrets |

## Secrets Manager (criados pelo tx01v2; valores nunca no state/plan)

- `tx01v2-lab/db/app`: JSON com valores string `username`, `password`, `host`, `port`, `dbname`.
- `tx01v2-lab/app/admin-token`: string pura, 48 caracteres alfanuméricos aleatórios.
- O papel do ESO lê os dois (e decifra com a chave KMS do lab); o deployer não lê o Secrets Manager.

## Camada de plataforma (instalada pelo tx01v2)

- AWS Load Balancer Controller em `kube-system`, IngressClass `alb`.
- External Secrets Operator no namespace `external-secrets`; ClusterSecretStore `aws-secrets-manager`
  (provider aws, SecretsManager, região do SSM; só aceita ExternalSecrets do namespace `dx01v2`).
- Add-ons do EKS: vpc-cni (com enforcement de network policy), kube-proxy, coredns,
  eks-pod-identity-agent, metrics-server (usado pelo HPA da API).

## Runtime do app (dx01v2)

- Secret `db-credentials`: chaves `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  (AWS: ExternalSecret de `tx01v2-lab/db/app`; kind e compose: gerado em tempo de execução com
  valores aleatórios por `scripts/e2e-kind.sh` e `scripts/dev-env.sh`).
- Secret `app-secrets`: chave `ADMIN_TOKEN` (AWS: ExternalSecret de `tx01v2-lab/app/admin-token`).
- TLS do banco: AWS `DB_SSL_MODE=verify-full`, `DB_SSL_CA_FILE=/etc/rds-ca/ca.pem` a partir do
  ConfigMap `rds-ca` (criado pelo deploy a partir de
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`); local `DB_SSL_MODE=disable`.
  Com `APP_ENV=lab` a API recusa qualquer modo diferente de `verify-full`.
- Services: `api` (porta 3000 http, 9464 métricas), `web` (porta 8080).
- Ingress (só AWS): classe `alb`, `internet-facing`, `target-type: ip`, HTTP 80 (HTTPS só se um ARN
  de certificado ACM for informado: overlay `aws-https`), anotação
  `alb.ingress.kubernetes.io/wafv2-acl-arn` vinda do SSM; `/api` → `api:3000`, `/` → `web:8080`;
  health checks web `/healthz`, api `/readyz`.
- RDS PostgreSQL 17, porta 5432, acessível só a partir do security group do cluster EKS,
  `rds.force_ssl = 1`.

## Lab local (contrato local do tx01v2, versão 2)

O deploy local (scripts/deploy-local.sh, docs/LAB_LOCAL.md) lê o ConfigMap `lab-system/lab-contract`
da plataforma local do tx01v2, exige a versão `2` e recusa valores diferentes dos fixados no overlay
`local-platform`: `registry` = `registry.tx01v2.local`, `db.secret-name` = `tx01v2-lab-db-app`,
`app.admin-token-secret-name` = `tx01v2-lab-app-admin-token`, `eso.cluster-secret-store` =
`local-secrets`, `gateway.class` = `istio`, `tls.cluster-issuer` = `lab-ca`, `argocd.project` = `dx01v2`,
`monitoring.prometheus-service-account` = `monitoring/kube-prometheus-stack-prometheus`,
`tracing.otlp-endpoint` = `http://opentelemetry-collector.monitoring.svc:4318` (versão 2: o
`OTEL_EXPORTER_OTLP_ENDPOINT` da API e as NetworkPolicies até o Collector). Do contrato ele
lê ainda `registry-push`, `network-cidr`, `db.endpoint-ip`, `db.ca-configmap`, `gitops.push-url`,
`gitops.read-url` e `gitops.push-key-secret`. A fonte da verdade é o `docs/CONTRATO.md` do tx01v2.

## Mudando o contrato

1. Abra PRs nos dois repositórios, com links cruzados, e incremente a versão no título dos dois
   arquivos `docs/CONTRATO.md`.
2. Atualize os checks que cobrem o item (tabela "Como o contrato é verificado aqui"):
   `scripts/check-manifests.mjs`, `scripts/deploy-aws.sh`, `scripts/lib/k8s.sh`.
3. Faça o merge do lado que publica (tx01v2) antes do lado que consome (este), salvo remoções
   (ao contrário).
