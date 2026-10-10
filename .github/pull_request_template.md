## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Definition of Done

- [ ] `make verify` passes locally (or in the devcontainer) with `HARNESS_STRICT=1`; `make build` and `make e2e` too when images, manifests or the app changed
- [ ] CI is green (`static`, `test`, `images`, `e2e`)
- [ ] Docs updated in this PR (README status matrix, docs/*, CHANGELOG `[Unreleased]`)
- [ ] No new scanner ignore, or each new one has `statement` + `expired_at` and is explained below
- [ ] No coverage threshold lowered and no check disabled or skipped
- [ ] No IAM, network (NetworkPolicy), RBAC or CORS widening, or the reason is stated below
- [ ] Contract (docs/CONTRATO.md) unchanged, or version bumped with a coordinated tx01v2 PR linked below
- [ ] Every new dependency, action or image is pinned (exact npm version + lockfile / commit SHA / digest)
- [ ] No secrets or real identifiers (account IDs, IPs, e-mails) in code, docs or examples

## Cloud impact

<!-- "None" for app/harness/docs changes that do not touch deploy-aws. Otherwise: what changes in
     the EKS deploy and the cost impact. Nothing here has run in AWS unless a cloud_run_report
     issue says so. -->

## Notes for the reviewer
