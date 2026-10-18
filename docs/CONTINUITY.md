# R9 — data, regional loss and failback

Status: implementation delivered; the `continuity` job publishes measurements for
each revision. v2 has not run in AWS. A Docker result does not establish managed
SLA, latency, replication or RDS promotion.

## Reproducible experiment without a cloud account

`make continuity` requires the two images already built by CI. This is a heavy
Actions exercise and does not build images different from those approved by scanners.

1. Create A/B with independent frontend/backend networks and disks. No database
   publishes a host port; only the app publishes HTTP on loopback at a random port.
2. Recover ephemeral configuration/secrets using checksums. Verify image IDs;
   the bundle and private keys never enter artifacts.
3. Run PostgreSQL with verify-full TLS, ephemeral CA and SAN db. API mounts only
   the public CA; database and frontend never directly share a network.
4. Write a marker through API→nginx→database, demonstrate failed reads, restart
   the database and require recovery through the same API without restarting it.
5. Run pg_dump -Fc, verify catalog/SHA256, write a later transaction, and require
   promotion to be refused while the primary is alive.
6. Corrupt a backup copy and require rejection before restore.
7. Stop every A writer, verify fencing and destroy A's disk. Restore B from the
   intact backup and start the identical application version.
8. Require the pre-backup marker and absence of the later transaction. Measure
   RPO from consistent backup start to failure; RTO from failure until B serves
   and verifies data. Local bounds:120s/180s.
9. Write in B, take a new backup, fence B and rebuild A on a fresh disk. Failback
   must preserve original and B-written data within180s; B must remain unable to write.

Report `continuity/continuity.json` contains checksums, image IDs, RPO/RTO,
failback time and the intentional one-transaction loss. Errors fail the job.
Cleanup verifies each resource's unique run label before removal; it never uses
another task's volume, network, Kubernetes context or Compose project.

## What each layer recovers

| Layer | Mechanism | Evidence |
|---|---|---|
| API reconnection | Pool discards broken connection, opens another | DB interruption, same API container |
| Logical application backup | pg_dump, catalog, SHA256 | Marker preserved, corruption rejected |
| Physical archive/WAL/PITR | tx01v2 exercise | Verified base backup, restore point, deleted transaction recovered |
| Kubernetes PVC | tx01v2 Velero | Coordinated TX volume-data drill verifies checksum after original PVC removal |
| Environment loss/failback | Independent A/B networks/disks | continuity job, fencing, new data preserved |
| Images/supply chain | images job artifact, signed release/deploy | Same IDs in A/B, R7 gates |
| Managed DB/runtime | dr profile and TX runbook | Terraform mock/validation; not run in cloud |

In AWS verify plan and regional contract before changes. Freeze GitOps/deploys
and old writers before replica promotion; DNS alone cannot prevent split brain.
Follow the pair's runbooks, monitor lag, record RPO/RTO, and fail back only after
consistent reseeding. If the primary cannot be isolated, stop promotion and
escalate to the operator.

Never copy local .env into cloud. Regional secrets remain in Secrets Manager
and workloads use regional identities. Promotion publishes approved release
images to the recovered region's registry without rebuilding.

## Recovery-region deployment and data

Contract v7 selects the destination's EKS, registry, network, WAF, ACM certificate
and RDS endpoint. target=secondary reads /tx01v2/lab-dr/, publishes gitops/aws-dr
and uses LAB_DR_REGION (default us-west-2). First configure TX DR and its regional
platform. The registry receives approved release images with signed final
destination promotion statements.

Secrets Manager replicates **current** username/password/token under the same
names in the other region. ESO overrides only DB_HOST with db/endpoint.
Deployment cannot read Secrets Manager values. All16 SSM keys are read in batches
of at most10 (API limit); a missing/failed batch blocks deployment.

After fencing and authorized promotion, smoke reaches the secondary ALB while
using the public hostname and verified TLS, before changing DNS. It requires the
published revision and a write/read. Only then enable secondary ExternalDNS in
the TX workflow (activate_dns=true); it starts at zero replicas.

Escrow the full-profile Velero repository key outside both regions and preserve
required state/backup recovery copies. Runtime target selection and DNS activation
do not promote a database or certify recoverability. See TX CONTINUITY for
retention, bucket deletion and key lifecycle during teardown.
