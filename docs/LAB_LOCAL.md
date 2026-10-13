# O app na plataforma local

O tx01v2 monta, no Docker, a plataforma completa que o lab v1 só tinha na nuvem (Istio, cert-manager,
External Secrets, Prometheus/Alertmanager/Grafana, Loki/Alloy, Argo CD, Gatekeeper, Trivy Operator,
Velero, Chaos Mesh) em cima de um kind com ECR, RDS, S3, load balancer e servidor git emulados
(`docs/LAB_LOCAL.md` do tx01v2). Este repositório faz o deploy do app nela do jeito GitOps e prova o
comportamento com sondas. Nada aqui fala com a AWS.

Status: `verificado no CI` (job `e2e-platform`, 13 sondas) e `verificado localmente` (2026-10-13).

## Como rodar

```bash
make build           # imagens dx01v2-api:e2e e dx01v2-web:e2e (ou deixe o e2e construir)
make e2e-platform    # sobe o lab do tx01v2, faz o deploy, roda as sondas e destrói tudo
```

O script clona o tx01v2 no commit de `deploy/local/tx01v2.ref`; com `TX01V2_DIR=<checkout>` ele usa
um checkout seu. `KEEP_LAB=1` mantém o lab no fim (`bash <tx01v2>/scripts/local-lab.sh down` depois).
Dentro de um contêiner que usa o Docker do host, exporte `LOCAL_KIND_INTERNAL=1`. Precisa de Docker com
8 GB de memória.

Com o lab do tx01v2 já de pé (`make local-up` lá), o deploy sozinho:

```bash
export KUBECONFIG="$(bash ../tx01v2/scripts/local-lab.sh kubeconfig)"
GIT_SHA=$(git rev-parse HEAD) scripts/deploy-local.sh
```

## Como o deploy funciona (`scripts/deploy-local.sh`)

1. Lê o contrato local `lab-system/lab-contract` (versão 1) e recusa valores diferentes dos fixados no
   overlay (registry, segredos, ClusterSecretStore, GatewayClass, issuer, AppProject).
2. Envia as imagens para o registry do lab com a tag do commit (`localhost:5001/dx01v2/*:<sha>`; no
   cluster elas se chamam `registry.tx01v2.local/dx01v2/*`).
3. Copia a CA do lab para o ConfigMap `lab-ca` do namespace (a API usa `DB_SSL_MODE=verify-full`).
4. Renderiza `deploy/k8s/overlays/local-platform` com os valores do contrato e faz commit no repositório
   GitOps do servidor git do lab (push com a chave de `lab-secrets/gitops-push-key`).
5. Cria a Application `dx01v2` (AppProject `dx01v2`, prune e self-heal) e espera Synced/Healthy, os
   rollouts e o Gateway `Programmed`.

O overlay `local-platform` acrescenta à `base`: Gateway `dx01v2` (classe `istio`, HTTPS com o
certificado do `lab-ca`, HTTP → 301) e HTTPRoutes (`/api` → api:3000, `/` → web:8080);
ExternalSecrets de `local-secrets`; HPA 2-4; `PeerAuthentication` `STRICT` e `AuthorizationPolicy` por
identidade (Gateway e web para a API, Gateway para o web, Prometheus para a porta de métricas);
NetworkPolicies com HBONE (15008) e as sondas do kubelet do ambient (`169.254.7.127/32`); saída da API só
para o banco (`/32`); ServiceMonitor, cinco regras de alerta e um dashboard do Grafana.

## O que as sondas provam (`scripts/e2e-platform.sh`)

| Sonda | O que prova |
|---|---|
| gitops | as imagens estão no registry do lab, o Argo CD sincronizou o commit (Synced, Healthy) e recria um objeto apagado |
| backup | `pg_dump` do banco do lab, mensagem apagada pela API, restore traz de volta |
| smoke | o smoke test inteiro (`e2e/smoke.mjs`) por HTTPS em `dx01v2.tx01v2.local`, de fora do mesh: load balancer emulado → Gateway do Istio → app, certificado conferido contra a CA do lab |
| mesh | um cliente em texto puro fora do mesh não chega na API |
| observability | Prometheus coleta a API pelo mesh, as cinco regras estão carregadas, há métricas do tráfego do smoke, o Grafana carregou o dashboard, os logs da API estão no Loki |
| trivy | o Trivy Operator gerou relatórios de vulnerabilidade das imagens do app |
| hpa | o HPA está `ScalingActive` (metrics-server) |
| chaos | hipótese: com 2 réplicas, matar um pod da API não interrompe as leituras (pelo menos 38 de 40) |

As regras de alerta também são testadas sem cluster pelo `promtool` (check `promtool-rules`,
`deploy/k8s/components/local-platform/alerts-test.yaml`).

## Limites

- Tudo roda num nó kind; nada disso prova o comportamento no EKS (o deploy na AWS continua
  `não executado em nuvem (v2)`).
- A API vê o endereço do load balancer emulado como cliente (o Envoy dele é TCP): o rate limit vale para
  todos os clientes juntos no lab local.
- O ConfigMap `lab-ca` é criado pelo deploy, fora do GitOps (como o `rds-ca` na AWS).
