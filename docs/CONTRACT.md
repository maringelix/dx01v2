# Contract tx01v2 <-> dx01v2 — version 7 (2026-10-17)

Version 7 (R9) adds `db/endpoint`, bringing the current contract to 16 parameters.
The `dr` profile also publishes `/tx01v2/lab-dr/` in the secondary region for its
cluster, VPC, registry, WAF, regional certificate and private replica. Secrets
Manager replicates the **values already stored**, encrypted with the secondary
region's KMS key; enabling DR does not generate another password. Secret names
remain identical in both regions, and regional ESO replaces only `DB_HOST` with
the endpoint from its contract. The plan does not read credentials.

Version 5 adds optional public DNS and HTTPS: tx validates ACM through DNS in an
existing Route53 hosted zone, publishes `dns/*` in SSM and installs ExternalDNS with
Pod Identity restricted to the hostname and zone. dx selects the HTTPS overlay
and sets the hostname from this contract, without a manually supplied ARN (R8.1).

Version 6 publishes `alb/source-cidr`, the smallest CIDR covering only the ALB's
public subnets. The app NetworkPolicy uses this range for incoming web traffic;
`vpc-cidr` remains limited to API egress to private RDS (R8.1).

In the `full` profile, tx installs the `dx01v2-waypoint` waypoint, mTLS and
authorization policies, app metrics and alerts, and Kyverno. Before deployment,
dx promotes only approved GHCR digests, signs the ECR promotion statement and
pins the promoted digests in manifests. Kyverno requires the keyless statement
from the fork's exact `deploy-aws.yml` workflow identity (R8.2–R8.4).

Version 4 integrates the `full` layer with Istio ambient and Gatekeeper and
registers the dx `gitops/aws` revision in Argo CD; the `dx01v2-deployers` group can
request a refresh of the `dx01v2` Application (R4.1/R4.4). Version 3 (2026-10-15)
pins GitHub OIDC subjects to immutable owner and repository IDs and restricts
deployment to `main`. Version 2 (2026-10-14) adds traces through the Collector to
AWS X-Ray. The dx R4 PR coordinates version 4 of this contract.

This is the app-consumed interface between infrastructure (tx01v2) and this
repository. The authoritative source is
[tx01v2/docs/CONTRACT.md](https://github.com/maringelix/tx01v2/blob/main/docs/CONTRACT.md);
that file takes precedence over any discrepancy. Every interface change requires
coordinated PRs and a version increment in both repositories.

## How this contract is verified here

| What | Where | Status |
|---|---|---|
| Service names, ports, probes, Secrets, ConfigMap, Ingress class/annotations/routes/health checks, ExternalSecrets, HPA, NetworkPolicies, only deployer-writable kinds | contract-app (scripts/check-manifests.mjs on rendered overlays) | verified locally |
| v2 OTLP endpoint in API ConfigMap, NetworkPolicy only to observability Collector port4318 | contract-app | verified locally |
| Valid Kubernetes1.36 and external-secrets.io/v1 ExternalSecret manifests | strict kubeconform | verified locally |
| Exactly16 SSM parameters below, /tx01v2/lab prefix, rds-ca from official bundle | contract-app checks scripts/deploy-aws.sh | verified in CI after merge |
| SSM formats: ECR URLs, WAF/ACM ARNs, VPC CIDR | k8s_validate_params in scripts/lib/k8s.sh, rendering with params.example.env | verified locally |
| Fixed cluster/secret/store values match SSM | deploy-aws.sh rejects discrepancies before applying | not run in the cloud (v2) |
| Actual AWS behavior | docs/RUNBOOK.md | not run in the cloud (v2) |

## Identifiers

| Item | Value |
|---|---|
| AWS region | Terraform variable `aws_region`, default `us-east-1` |
| Project / environment / prefix | `tx01v2` / `lab` / `tx01v2-lab` |
| Default tags (provider `default_tags`) | `Project=tx01v2`, `Environment=lab`, `ManagedBy=terraform`, `Repository=<owner>/tx01v2` |
| EKS cluster | `tx01v2-lab`, Kubernetes `1.36` (recorded standard EKS support through 2027-08-02), `upgrade_policy.support_type = "STANDARD"` |
| App namespace | `dx01v2`, created by tx with `pod-security.kubernetes.io/enforce=restricted`, `pod-security.kubernetes.io/enforce-version=latest` and `elbv2.k8s.aws/pod-readiness-gate-inject=enabled`; `full` also adds `istio.io/dataplane-mode=ambient` and `policy.lab/enforce=true` |
| Deployer Kubernetes group | `dx01v2-deployers`, bound in namespace `dx01v2` by RoleBinding `dx01v2-deployers` to Role `dx01v2-deployer` |
| Traces (OpenTelemetry) | `http://opentelemetry-collector.observability.svc:4318` (OTLP/HTTP); the platform installs the Collector in `observability` with Pod Identity `tx01v2-lab-otel-collector` and only `AWSXRayDaemonWriteAccess`; spans go to AWS X-Ray in the lab region |
| ECR repositories | `dx01v2/api`, `dx01v2/web`, IMMUTABLE tags and scan on push; images use the full dx01v2 Git SHA tag (40 characters) |
| GitHub OIDC roles (tx01v2 bootstrap) | `tx01v2-gha-plan`, `tx01v2-gha-apply`, `dx01v2-gha-deploy` |
| EKS Pod Identity (`full`) | `trivy-system/trivy-operator`, `kyverno/kyverno-admission-controller`, `kube-system/ebs-csi-controller-sa`; Trivy and Kyverno can read only the two app ECR repositories |

Role `dx01v2-deployer` rules in namespace `dx01v2`, present in both `core` and `full`:

- `apps`: deployments → get, list, watch, create, update, patch, delete; replicasets → get, list, watch.
- Core: services, configmaps, serviceaccounts → get, list, watch, create, update,
  patch, delete; pods, pods/log, events, endpoints → get, list, watch; secrets →
  get, list, watch. ESO writes the secrets; the deployer never writes them.
- `networking.k8s.io`: ingresses, networkpolicies → full CRUD (same verbs as deployments).
- `autoscaling`: horizontalpodautoscalers → full CRUD; `policy`: poddisruptionbudgets → full CRUD.
- `external-secrets.io`: externalsecrets → full CRUD.

In `full`, additive Role `dx01v2-deployer-full` permits `HTTPRoute`,
`DestinationRule` and `AuthorizationPolicy` only in namespace `dx01v2`, plus `get`
only for the `dx01v2-waypoint` Gateway used by preflight. ClusterRole
`dx01v2-deployer-namespace-read` allows only `get` on Namespace `dx01v2` to read its
ambient labels; it cannot list or modify namespaces. All bindings target only
`dx01v2-deployers`. The Argo CD AppProject admits the app kinds only in this
profile; `platform/uninstall.sh` removes all additive RBAC.

## GitHub OIDC trust

Exact `sub` (StringEquals, no wildcards), audience `sts.amazonaws.com`,
configurable owner (`github_owner`, no default: the repository or fork owner).
GitHub's **immutable** `sub` format (repositories created after 2026-07-15 or
opted in) includes the numeric owner and repository IDs (`github_owner_id`,
`tx01v2_repository_id`, `dx01v2_repository_id`), so re-registering a deleted account
name does not inherit the lab. Environment `lab` deploys only from `main`.

| Role | Allowed `sub` |
|---|---|
| `tx01v2-gha-plan` | `repo:<owner>@<owner id>/tx01v2@<repo id>:pull_request`, `repo:<owner>@<owner id>/tx01v2@<repo id>:ref:refs/heads/main` |
| `tx01v2-gha-apply` | `repo:<owner>@<owner id>/tx01v2@<repo id>:environment:lab` |
| `dx01v2-gha-deploy` | `repo:<owner>@<owner id>/dx01v2@<repo id>:environment:lab` |

Role `tx01v2-gha-plan` reads only lab services (Describe/Get/List), rather than
the entire account. Apply does not use `PowerUserAccess`: its policy permits the
AWS service families needed by the lab; IAM is limited to `tx01v2-*` names and
requires the boundary. S3 covers only state and the Velero bucket. When enabled,
Route53 is limited to the hosted zone also configured during bootstrap. The lab
roles' boundary caps the same service families, limits S3 to the Velero bucket
and Route53 to the configured zone, and excludes general IAM, Organizations and
account administration APIs.

The boundary separately permits `eks-auth:AssumeRoleForPodIdentity` only for the
primary and DR clusters: EKS Auth is not part of `eks:*`. Node roles retain
`AmazonEKSWorkerNodePolicy`, and Pod roles retain component-specific policies.
The only IAM creation allowed to a workload is the standard ELB service-linked
role, at this account's exact ARN with an ELB service condition, required for the
first ALB.

Role `dx01v2-gha-deploy` permits `ecr:GetAuthorizationToken` on `*`; push/pull and
`ecr:DescribeImages`, used to resolve the promoted digest, only on the two app ECR
repositories in the primary/DR regions; `eks:DescribeCluster` on the owned primary
and DR cluster ARNs; and `ssm:GetParameter`, `ssm:GetParameters` and
`ssm:GetParametersByPath` on the primary/DR contract paths. Kubernetes access uses
an EKS access entry (type `STANDARD`,
`kubernetes_groups = ["dx01v2-deployers"]`), created by the lab root for each ARN
in `app_deployer_principal_arns`.

Usage note (does not alter the contract): with `GetParametersByPath`, use
`Path=/tx01v2/lab/` with the trailing slash, matching
`parameter/tx01v2/lab/*`; alternatively read exact names with `GetParameter(s)`.

## SSM parameters (String, written by the lab root), prefix `/tx01v2/lab/`

| Name | Value |
|---|---|
| `region` | AWS region |
| `cluster-name` | `tx01v2-lab` |
| `vpc-id` | VPC ID |
| `vpc-cidr` | VPC CIDR (API → RDS NetworkPolicy) |
| `alb/source-cidr` | CIDR covering only public subnets hosting ALB nodes (web → pods) |
| `ecr/api-url` | `dx01v2/api` repository URL |
| `ecr/web-url` | `dx01v2/web` repository URL |
| `waf/acl-arn` | REGIONAL WAFv2 web ACL ARN for the app ALB |
| `db/secret-name` | `tx01v2-lab/db/app` |
| `db/endpoint` | Selected private RDS hostname; replaces the host in the replicated JSON |
| `app/admin-token-secret-name` | `tx01v2-lab/app/admin-token` |
| `eso/cluster-secret-store` | `aws-secrets-manager` |
| `dns/enabled` | `true` when domain and zone are configured; otherwise `false` |
| `dns/domain-name` | Public app hostname or `disabled` |
| `dns/zone-id` | Existing public hosted zone ID or `disabled` |
| `dns/acm-certificate-arn` | ACM certificate with completed DNS validation or `disabled` |

## Secrets Manager (created by tx01v2; values use write-only arguments, never state/plan)

- `tx01v2-lab/db/app`: JSON with string values `username`, `password`, `host`, `port` and `dbname`.
- `tx01v2-lab/app/admin-token`: plain string, 48 random alphanumeric characters.
- Encrypted with the lab KMS key. The ESO role can use
  `secretsmanager:GetSecretValue` and `DescribeSecret` on
  `arn:aws:secretsmanager:<region>:<account>:secret:tx01v2-lab/*`, and
  `kms:Decrypt` on the lab key with
  `kms:ViaService = secretsmanager.<region>.amazonaws.com`.

## Platform layer (installed by tx01v2, outside Terraform)

- AWS Load Balancer Controller in `kube-system`, ServiceAccount
  `aws-load-balancer-controller` (EKS Pod Identity), IngressClass `alb`.
- With `dns/enabled=true`, ExternalDNS runs in `kube-system` as `external-dns`
  through Pod Identity. Its role reads the selected zone and changes only the
  app A record and TXT `a-_external-dns-<hostname>` in that zone. ExternalDNS is
  not installed without a domain.
- External Secrets Operator in `external-secrets`, ServiceAccount
  `external-secrets` (EKS Pod Identity), ClusterSecretStore
  `aws-secrets-manager` (AWS provider, SecretsManager service, SSM-supplied
  region, no explicit auth → controller credentials). tx01v2 restricts the store
  to ExternalSecrets from namespace `dx01v2` (`spec.conditions`).
- Terraform-managed EKS add-ons: vpc-cni (with network policy enforcement),
  kube-proxy, coredns, eks-pod-identity-agent, metrics-server and EBS CSI.
- `platform/install.sh --profile full` installs Istio ambient, the L7 waypoint,
  Gatekeeper, Kyverno, Trivy Operator, Argo CD, persistent observability, Velero
  and Chaos Mesh. `core` remains the default.
- In `full`, Application `platform` reads tx `platform/gitops` and passes the
  public dx URL and `gitops/aws` revision through `valuesObject`. The chart
  registers Application `dx01v2` watching `deploy/k8s/overlays/aws` with automatic
  sync, prune and self-heal. Fork operators must configure Argo CD credentials
  for private repositories.
- The deploy workflow updates the live Application's overlay, images and cloud
  parameters. Application `platform` ignores only `spec.source.path`,
  `spec.source.kustomize.images` and `spec.source.kustomize.patches` on Application
  `dx01v2`, so parent self-heal preserves these values. Public branch
  `gitops/aws` receives the revision and example parameters; actual IDs and CIDRs
  remain in the cluster.
- Kubernetes group `dx01v2-deployers` has RoleBinding `dx01v2-gitops-sync` in
  `argocd`: it can `get`, `list`, `watch` and `patch` Application `dx01v2`.
  Listing is needed by the Kubernetes client; `get/watch/patch` are restricted
  to `resourceNames: [dx01v2]`. This allows a deploy to request refresh, without
  creating or modifying other Applications. Role `dx01v2-deployer` in namespace
  `dx01v2` remains limited to app resources.
- In `full`, ambient mesh uses `STRICT` mTLS between workloads, identity
  authorization and a waypoint for L7 routes. The ALB HTTP exception is limited
  to web and the public-subnet CIDR. Constraint `allowed-repos` and the Kyverno
  policy protect Pods in namespace `dx01v2`.
- Trivy Operator and Kyverno obtain temporary ECR credentials through Pod
  Identity and can read only `dx01v2/api` and `dx01v2/web`. Kyverno fails closed
  when a digest lacks a promotion attestation signed by the fork's exact
  workflow. Policy configuration is checked offline; AWS runtime remains
  `not run in the cloud (v2)`.

## App runtime (dx01v2)

- Secret `db-credentials`: keys `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
  `DB_PASSWORD` (AWS: ExternalSecret from `tx01v2-lab/db/app`; Compose/kind:
  generated at runtime).
- Secret `app-secrets`: key `ADMIN_TOKEN` (AWS: ExternalSecret from
  `tx01v2-lab/app/admin-token`).
- Database TLS: AWS `DB_SSL_MODE=verify-full` and
  `DB_SSL_CA_FILE=/etc/rds-ca/ca.pem` from ConfigMap `rds-ca`, created during
  deployment from
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`.
  Basic Compose/kind uses `DB_SSL_MODE=disable`; the complete local platform uses
  its own TLS contract below.
- Services: `api` (HTTP port 3000, metrics 9464), `web` (port 8080).
- AWS Ingress: class `alb`, `internet-facing`, `target-type: ip`, WAF from SSM,
  route `/` → `web:8080`; web nginx proxies `/api` to `api:3000`. Without configured DNS this
  remains HTTP-only. With DNS, dx uses `aws-https`, the contract hostname and ACM
  certificate; HTTP redirects to HTTPS and ExternalDNS maintains the A record.
  Health checks: web `/healthz`, API `/readyz`.
- RDS PostgreSQL 17 on port 5432, accessible only from the EKS cluster security
  group, `rds.force_ssl = 1`.

## Local lab (local contract, version 2)

The local lab (`docs/LOCAL_LAB.md`) has a separate contract and version
(`version` key), consumed by dx01v2 local deployment. It mirrors cloud interfaces
with local lab names and does not change the cloud contract above.
`platform/local/install.sh` publishes it in ConfigMap `lab-system/lab-contract`:

| Key | Value | Cloud equivalent |
|---|---|---|
| `version` | `2` (2026-10-14: `tracing.otlp-endpoint`; version 1 had no traces) | This file's version |
| `cluster-name` | `tx01v2-local` | `cluster-name` |
| `network-cidr` | `10.250.0.0/24` (or `subnet_cidr`) | `vpc-cidr` |
| `registry` | `registry.tx01v2.local` (image name inside the cluster) | `ecr/api-url`, `ecr/web-url` (prefix) |
| `registry-push` | `localhost:5001` (push from this machine) | — |
| `db.endpoint-ip`, `db.hostname`, `db.port` | `10.250.0.11`, `db.tx01v2.local`, `5432` | RDS endpoint |
| `db.secret-name` | `tx01v2-lab-db-app` (keys `host`, `port`, `dbname`, `username`, `password`) | `db/secret-name` |
| `db.ca-configmap` | `lab-system/lab-ca` (key `ca.crt`) | RDS CA bundle |
| `app.admin-token-secret-name` | `tx01v2-lab-app-admin-token` (key `token`) | `app/admin-token-secret-name` |
| `eso.cluster-secret-store` | `local-secrets` (only namespace `dx01v2`) | `eso/cluster-secret-store` |
| `gateway.class` | `istio` (Gateway API) | IngressClass `alb` |
| `tls.cluster-issuer` | `lab-ca` (cert-manager) | ACM certificate |
| `gitops.push-url`, `gitops.read-url` | `ssh://10.250.0.13:23231/dx01v2-gitops`, `http://10.250.0.13:23232/dx01v2-gitops.git` | — |
| `gitops.push-key-secret` | `lab-secrets/gitops-push-key` (SSH push key, `kubernetes.io/ssh-auth`) | `dx01v2-gha-deploy` role |
| `argocd.project` | `dx01v2` (AppProject: only the GitOps repository, namespace `dx01v2` and deployment kinds; no Secret or cluster resource) | `dx01v2-deployer` Role |
| `monitoring.prometheus-service-account` | `monitoring/kube-prometheus-stack-prometheus` (Prometheus mesh identity) | — |
| `tracing.otlp-endpoint` | `http://opentelemetry-collector.monitoring.svc:4318` (Collector OTLP/HTTP; app spans flow through it over the mesh, and Gateways send their spans through OTLP/gRPC on port 4317) | — |

Local namespace `dx01v2` uses Pod Security `restricted`, ambient mesh
(`istio.io/dataplane-mode: ambient`), Gatekeeper constraints in `deny`
(`policy.lab/enforce: "true"`; images only from `registry.tx01v2.local/`), and
Prometheus in namespace `monitoring` scrapes app metrics. Local deployment writes
to the GitOps repository; Argo CD applies the changes to the cluster.

## Application consumption and regional deployment

The deploy workflow selects platform_profile=core|full to match TX installation;
DNS plus profile selects aws, aws-https, aws-full or aws-https-full. Full requires
the programmed ambient waypoint and includes canary/retries/circuit-breaking.

For DR, target=secondary reads /tx01v2/lab-dr/ in LAB_DR_REGION, selects that
region's EKS/ECR/WAF/ACM/RDS and publishes gitops/aws-dr. Secrets Manager copies
current values without changing names; ESO overrides only DB_HOST using
db/endpoint, preserving username/password/port/database.

| SSM key | Use in dx01v2 |
|---|---|
| region | Compare with AWS_REGION |
| cluster-name | aws eks update-kubeconfig |
| vpc-id | Read and verify presence |
| vpc-cidr | API→RDS egress (VPC_CIDR) |
| alb/source-cidr | Web ingress (ALB_SOURCE_CIDR) |
| ecr/api-url | API_IMAGE |
| ecr/web-url | WEB_IMAGE |
| waf/acl-arn | alb.ingress.kubernetes.io/wafv2-acl-arn (WAF_ACL_ARN) |
| db/secret-name | Compare with db-credentials ExternalSecret |
| db/endpoint | Secret DB_HOST template and verify-full TLS |
| app/admin-token-secret-name | Compare with app-secrets ExternalSecret |
| eso/cluster-secret-store | Compare with ExternalSecrets secretStoreRef |
| dns/enabled | HTTP/HTTPS selection combined with core/full |
| dns/domain-name | Ingress hostname and smoke URL |
| dns/zone-id | Verify before render; app deployment does not alter zone |
| dns/acm-certificate-arn | ALB HTTPS listener |

Deployer does not read Secrets Manager: ESO reads/decrypts the contract secrets.
AWS app images are approved GHCR images promoted without rebuild and pinned by
their final ECR digests, rather than locally rebuilt images. APP_ENV=lab requires
DB_SSL_MODE=verify-full with DB_SSL_CA_FILE. The namespace and RBAC belong to TX;
aws* overlays never create the namespace and contract-app rejects other kinds.

In full Argo CD owns app manifests. Deployment configures path/images/real
parameters in the live argocd/dx01v2 Application, publishes the app revision and
example-copied params.env to gitops/aws and requests refresh. Parent ignores only
the child's path, Kustomize images/patches and uses RespectIgnoreDifferences=true.
Public Git receives no real account/project identifiers. Actions auto uses GitOps
when Application exists, direct push for core otherwise. DEPLOY_MODE=push can
support a non-Argo operator path, but a laptop script does not issue the
workflow-identity promotion attestations required by full admission.

Only web is public through ALB: /→web:8080, with web nginx forwarding /api to
api:3000. ALB health checks web /healthz; API /readyz remains its readiness probe.
NetworkPolicy web ingress uses alb/source-cidr, not the whole VPC.

Local deployment (scripts/deploy-local.sh) requires ConfigMap version2 and exact
local-platform values: registry=registry.tx01v2.local,
db.secret-name=tx01v2-lab-db-app,
app.admin-token-secret-name=tx01v2-lab-app-admin-token,
eso.cluster-secret-store=local-secrets, gateway.class=istio,
tls.cluster-issuer=lab-ca, argocd.project=dx01v2,
monitoring.prometheus-service-account=monitoring/kube-prometheus-stack-prometheus,
tracing.otlp-endpoint=http://opentelemetry-collector.monitoring.svc:4318.
Version2 adds the API OTLP endpoint and Collector NetworkPolicies. It also reads
registry-push, network-cidr, db.endpoint-ip, db.ca-configmap, gitops.push-url,
gitops.read-url and gitops.push-key-secret. TX is the authoritative local contract.

## Changing the contract

1. Open cross-linked PRs in both repositories and increment both CONTRACT title versions.
2. Update the checks in "How this contract is verified here": scripts/check-manifests.mjs, scripts/deploy-aws.sh and scripts/lib/k8s.sh.
3. Merge the publisher (tx01v2) before the consumer, except for removals, which use the reverse order.
