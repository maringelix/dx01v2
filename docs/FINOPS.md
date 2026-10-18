# R10 — app capacity, SLO and rightsizing

Construction for forks; `not run in the cloud (v2)`. The complete workflow uses tx01v2 pinned in
`deploy/local/tx01v2.ref`. Small remains one node/7 GiB; capacity uses `LOCAL_TOPOLOGY=ha` and
`LOCAL_FINOPS=1` with 12 GiB available to Docker recommended. Heavy runs belong in Actions.

## Exercise and evidence

CI `e2e-platform` executes `scripts/capacity-app.sh` after the previous probes.
On Linux/devcontainer with sufficient resources:

```bash
LOCAL_TOPOLOGY=ha LOCAL_FINOPS=1 make e2e-platform
```

The test accepts only the `kind-tx01v2-local` kubeconfig. It measures actual HTTPS requests to
`/api/messages` through the Gateway with a verified CA, without persisting/exposing credentials.
Every phase has bounded concurrency/duration, a Pod deadline and cleanup.

1. Measure a baseline with four clients for 30 seconds: success >=99%, p99 <=1.5 s.
2. Inject CPU StressChaos with an API CPU limit of 500m alongside HTTP load. Require four ready HPA replicas.
3. Drain only API Pods from a kind-owned worker. PDB, readiness and RollingUpdate stay active; the
   client must maintain the same SLO throughout the exercise.
4. Remove stress and require scale-down to two replicas. Trial CPU requests of 100m → 50m, rerun the
   same load/SLO and record actual replica counts and aggregate requests before/after.
5. Lock the PostgreSQL table for 10 seconds: require at least ten blocked API connections, pool
   saturation and visible client errors. On release, require recovery and repeat the SLO. More app
   replicas cannot fix a database bottleneck.
6. Require a VPA recommendation with `updateMode=Off`; quota must reject an expensive Pod exceeding
   CPU allowance. Evidence JSON contains counts/latency, never response bodies.

The Argo CD controller pauses during this imperative experiment. A trap restores requests, HPA and
the controller's original replica count, including on failure. GitOps manifests remain the permanent
configuration source. Normal HPA uses stabilization windows; only the test shortens scale-down.

## Showback and interpretation

Every app Pod template requires `cost.lab/owner` and `cost.lab/environment`; `contract-app` fails if
either label is absent. Set owner in Kustomize to the exercise owner. tx01v2 installs OpenCost and
Grafana; see the [infrastructure FinOps exercise](https://github.com/maringelix/tx01v2/blob/main/docs/FINOPS.md)
for allocation, idle/shared costs, source/date/currency/region and services outside Pods.

Lower requests do not guarantee savings: HPA may create more replicas. Compare aggregate requests,
measured use, latency, errors and allocation for the same load. The 50m candidate is an experiment
restored on exit; it never changes the permanent app configuration automatically.
VPA Off does not compete with HPA by mutating requests.

## AWS and cleanup

EKS uses Cluster Autoscaler with Pod Identity. The tx01v2 Spot lesson runs a disposable task with a
deadline and explicit on-demand fallback while preserving the critical app. More kind replicas do
not prove managed scaling or AWS prices. Use tx01v2's estimate, budget and expiration gate before
any apply. OpenCost is not an invoice, and a budget is not a billing ceiling.

On failure, inspect `capacity-app.json`, events, HPA/PDB/VPA, metrics-server, database pooling/
connections and Gateway logs. E2e teardown always destroys resources owned by its state and checks
leftovers. Cloud cleanup follows the pair's runbook and requires an authorized cloud run.
