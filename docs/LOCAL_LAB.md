# The application on the local platform

tx01v2 builds in Docker the complete platform that the v1 lab had only in cloud:
Istio, cert-manager, External Secrets, Prometheus/Alertmanager/Grafana, Loki/Alloy,
Tempo and OpenTelemetry Collector, Argo CD, Gatekeeper, Trivy Operator, Velero and
Chaos Mesh. It runs on kind with emulated ECR, RDS PostgreSQL, S3
Storage (through an S3 API emulator), load balancer and Git server (tx01v2's
`docs/LOCAL_LAB.md`). This repository deploys the application through GitOps and
proves its behavior with probes. Nothing here contacts AWS.

Historical evidence: verified in CI (e2e-platform, then 18 probes at default size;
e2e-platform-small, then 18 probes at small size with Docker limited to 7 GB), and verified locally
on 2026-10-13 (then 13 probes). Default full plus app exceeded the development Docker Desktop's
7.65 GiB; small fits 7 GB. Current probe sets extend this snapshot; CI reports are authoritative.
Current HA CI uses LOCAL_TOPOLOGY=ha/default size with 12 GiB Docker recommended.

## Run it

```bash
make build                         # dx01v2-api:e2e and dx01v2-web:e2e, or let the e2e build them
make e2e-platform                  # create tx01v2 lab, deploy, probe, destroy everything
LOCAL_SIZE=small make e2e-platform # same platform at small size (7 GB Docker)
```

The script clones tx01v2 at `deploy/local/tx01v2.ref`. `TX01V2_DIR=<checkout>`
uses an existing checkout; `TX01V2_REPO=<https URL>` clones another repository
(your fork; in CI, repository variable `TX01V2_REPO`, see `FORK.md`).
`KEEP_LAB=1` retains the lab afterward (then run
`bash <tx01v2>/scripts/local-lab.sh down`). Inside a container using the host's
Docker, export `LOCAL_KIND_INTERNAL=1`. Historical single-node full needs about 8 GB, or 7 GB with LOCAL_SIZE=small. Current HA uses 12 GiB/default size; small and HA cannot be combined.

With the tx01v2 lab already running (`make local-up` there), deploy alone:

```bash
export KUBECONFIG="$(bash ../tx01v2/scripts/local-lab.sh kubeconfig)"
GIT_SHA=$(git rev-parse HEAD) scripts/deploy-local.sh
```

`scripts/deploy-local.sh` rejects any kubectl context other than
`kind-tx01v2-local`: it never deploys to another currently selected cluster.

## The small size and the 7 GB evidence

`LOCAL_SIZE=small` reaches tx01v2's `platform/local/install.sh`: the same
components, with lower memory limits, short Prometheus/Tempo retention, fewer
series and workers (tx01v2's `docs/LOCAL_LAB.md` lists each chart's changes).
The application is unchanged. Values other than `default` or `small` fail before
any build.

`make e2e-platform-small` (CI job `e2e-platform-small`,
`scripts/e2e-platform-small.sh`) runs `e2e-platform` with `LOCAL_SIZE=small`
inside digest-pinned Docker-in-Docker (`docker:29.9.0-dind`), limited to 7 GB
without swap: the equivalent of a laptop allocating 7 GB to Docker. The job
result is the e2e result. Its summary includes peak memory of the whole daemon,
peak anonymous memory (page cache fills any limit; without swap, anonymous memory
cannot be reclaimed), largest containers and processes killed by the kernel for
lack of memory. It is not a ruleset-required check: default-size `e2e-platform`
gates the merge.

| Size | Docker | Result |
|---|---|---|
| `default` | 7 GB (local, 2026-10-15) | Failed: memory hit its limit about 825,000 times (thrashing), apiserver restarted and controllers entered CrashLoop; no OOM kill |
| `default` | CI runner, 16 GB | Passed (TX e2e and DX e2e-platform jobs) |
| `small` | 6 GB (CI, Docker-in-Docker, 2026-10-15) | Failed: 14 of 18 probes passed; rollout lost 7 of 376 requests; anonymous memory 4.25 GiB, limit hit 468,000 times, 4 OOM kills (Velero plugin copy) |
| `small` | 7 GB (CI, Docker-in-Docker, 2026-10-15) | Passed: 18 probes in about 14 minutes, anonymous memory 4.4 GiB. In one of four runs across the three pairs, the kernel killed the Velero plugin copy twice during installation (BestEffort init container, restarted by kubelet) |
| `small` | 8 GB (CI, Docker-in-Docker, 2026-10-15) | Passed in the same time, anonymous memory 4.37 GiB |

R1.8 targeted 6 GB; Bruno selected 7 GB on 2026-10-15, below development Docker Desktop's 7.65 GiB.
Historical peak working sets: apiserver 1248 MiB, Argo CD controller 306 MiB, Grafana 299 MiB plus
163 MiB for both sidecars, Prometheus 236 MiB, Trivy Operator 208 MiB, etcd 150 MiB, Gatekeeper's
two Pods 271 MiB; app API 57 MiB per Pod.

`e2e-platform-small` is heavy: besides its 7 GB, the inner daemon downloads every
lab image again. It is intended for the CI runner; on a 16 GB laptop with editor
and browser open, run `LOCAL_SIZE=small make e2e-platform` with Docker set to 7 GB.

## Deployment flow (`scripts/deploy-local.sh`)

1. Read local contract `lab-system/lab-contract` (version 2) and reject values
   that differ from the overlay's pinned registry, secrets, ClusterSecretStore,
   GatewayClass, issuer, AppProject and OTLP endpoint.
2. Push images to the lab registry (local ECR twin), using the commit tag:
   `localhost:5001/dx01v2/*:<sha>`; inside the cluster,
   `registry.tx01v2.local/dx01v2/*`.
3. Copy the lab CA to namespace ConfigMap `lab-ca`
   (the API uses `DB_SSL_MODE=verify-full`).
4. Render `deploy/k8s/overlays/local-platform` from the contract and commit it
   to the lab Git server's GitOps repository, pushing with
   `lab-secrets/gitops-push-key`.
5. Create Application `dx01v2` (AppProject `dx01v2`, prune and self-heal), wait
   for Synced/Healthy at the newly pushed commit (redeployment may still report
   Synced for the previous commit), rollouts and Gateway `Programmed`.

The overlay adds to `base`: Gateway `dx01v2` (class `istio`, HTTPS with a
`lab-ca` certificate, HTTP → 301) and HTTPRoutes (`/api` → api:3000,
`/` → web:8080, the local-platform routing); ExternalSecrets from `local-secrets`
(the local Secrets Manager twin); HPA 2–4; `PeerAuthentication` `STRICT` and identity
`AuthorizationPolicy` (Gateway/web to API, Gateway to web, Prometheus to metrics);
NetworkPolicies with HBONE (15008) and ambient kubelet probes
(`169.254.7.127/32`); API egress only to the database (`10.250.0.11/32`) and
OpenTelemetry Collector (OTLP/HTTP, `OTEL_EXPORTER_OTLP_ENDPOINT`); Gateway
egress to Collector (its spans, OTLP/gRPC), both through mesh HBONE;
ServiceMonitor, five alert rules and a Grafana dashboard. It uses only kinds
allowed by tx01v2's `dx01v2` AppProject (checked by `contract-app`).

## Connected traces, logs and metrics

The API creates a SERVER span per request (route name, never the raw path) and a
CLIENT span per PostgreSQL query inside it (parameterized SQL only; values never
enter spans). It continues the W3C `traceparent` sent by the Istio Gateway. Spans
travel through OTLP/HTTP to tx01v2's Collector, which writes to Tempo. Each log
line inside a request includes `trace_id`/`span_id`; the latency histogram stores
`trace_id` as an exemplar (`/metrics` uses OpenMetrics). In Grafana, follow the
latency chart to a trace, the trace to logs, and a log line back to its trace.
Without `OTEL_EXPORTER_OTLP_ENDPOINT` (Compose, kind, tests), nothing is exported.

## What the probes prove (`scripts/e2e-platform.sh`)

| Probe | Evidence |
|---|---|
| gitops | Images exist in the lab registry, Argo CD synchronized the commit (Synced/Healthy), and recreates a deleted object |
| backup | `pg_dump` of the lab database, deletion through API, restore recovers the message |
| smoke | Complete `e2e/smoke.mjs` with `SMOKE_EDGE=istio` over HTTPS at `dx01v2.tx01v2.local` outside the mesh: emulated load balancer → Istio Gateway → app, certificate checked against lab CA |
| mesh | Plaintext client outside the mesh cannot reach API |
| observability | Prometheus scrapes API through mesh, five rules are loaded, smoke traffic metrics exist, Grafana loaded its dashboard, API logs reached Loki |
| tracing | A read with `traceparent` appears in Tempo from edge to database (Gateway span, `GET /api/messages`, `SELECT dx01v2`); its Loki logs contain `trace_id` and Prometheus has a matching exemplar |
| trivy | Trivy Operator generated vulnerability reports for app images |
| hpa | HPA reports `ScalingActive` (metrics-server) |
| rollout | Hypothesis: a new version delivered through GitOps (new tags, `maxUnavailable: 0`, readiness, `preStop` and graceful shutdown) loses no request from a reader alternating API and web through the Gateway (zero downtime) |
| chaos | Hypotheses: with two replicas, killing an API Pod preserves reads (at least 38/40); adding 200 ms between API and PostgreSQL (`NetworkChaos`) preserves every read and shows the delay in its query span |

`SMOKE_EDGE=istio` routes `/api` directly to API (the API's own CSP,
one proxy hop: `TRUST_PROXY_HOPS=1`). Like nginx, a safe external `X-Request-Id`
returns unchanged (tx01v2's `gateway-preserve-request-id` EnvoyFilter; ALB preserves it). `promtool` also tests alert rules without a cluster
(`promtool-rules`, `deploy/k8s/components/local-platform/alerts-test.yaml`).

## Limits

- The historical default scenario runs on one kind node. None of it proves EKS,
  ALB/WAF, Secrets Manager, Pod Identity or RDS behavior; AWS
  deployment remains `not run in the cloud (v2)`. R10's HA topology is a separate
  capacity exercise, documented in `FINOPS.md`.
- The API sees the emulated load balancer's address as its client (its Envoy uses
  TCP): rate limiting aggregates all clients in the local lab.
- The deployment creates `lab-ca` outside GitOps (like AWS rds-ca).
- Rollout changes only image tags, keeping content identical: it proves delivery
  and Pod replacement, not an incompatible database migration.
