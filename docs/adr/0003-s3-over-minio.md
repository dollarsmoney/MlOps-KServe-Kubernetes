# ADR-0003: Use real S3 rather than in-cluster MinIO

- **Status:** Accepted
- **Date:** 2026-08-20
- **Affects:** Phase 2 (DVC remote), Phase 3 (MLflow artifacts), Phase 6 (model loading), Phase 14 (IRSA)

## Context

The DVC remote, the MLflow artifact store, and KServe's `storageUri` all need S3-compatible
object storage. Local MLOps tutorials usually run **MinIO** in the cluster to avoid cloud
dependencies.

Two facts pushed the other way. First, AWS credentials are already configured on this machine
in `us-east-1`, so there is no onboarding cost to using the real thing. Second, the local
cluster budget is tight: the host has 15.7 GB RAM, minikube gets 11 GB, and Knative/Istio,
Kafka, Postgres, Redis, Prometheus, Grafana, MLflow, and the application services all have to
fit. MinIO's ~1 GB is meaningful at that margin.

The deciding argument is Phase 14. With MinIO, the endpoint, the credential mechanism, and the
storage class all change when moving to AWS, and the IRSA lesson lands on infrastructure that
was never exercised locally. With real S3, Phase 14 changes exactly one thing — *how
credentials are obtained* — from a static key to a projected OIDC token. That isolates the
concept being taught.

## Decision

Use real AWS S3 from Phase 2 onward, in `us-east-1`, with prefixes for `raw/`, the DVC remote,
MLflow artifacts, and models.

Credentials: a local IAM user (already configured) during local phases; **IRSA** in-cluster
from Phase 14 — see [ADR-0001](0001-kserve-serverless-mode.md)'s sibling discussion in
[`architecture.md §7`](../architecture.md#7-aws-and-credential-handling).

## Consequences

**Gained**

- ~1 GB of cluster memory back, on a host where that matters.
- Storage behaves identically in every phase; Phase 14 changes only the credential mechanism.
- Real-world properties are exercised early: eventual consistency, network latency on artifact
  pulls, bucket policies, and lifecycle rules.

**Paid**

- Requires an internet connection and AWS credentials to run the pipeline. No fully offline
  development.
- Costs money — small: storage is pennies per month at this scale, but egress and request
  charges are non-zero. A lifecycle rule expires old experiment artifacts.
- Credentials must be handled carefully: `.env` is git-ignored, and no keys go into committed
  manifests.

**Rejected alternative:** MinIO in-cluster. Genuinely better for air-gapped or
zero-cost-constraint work, and a reasonable choice for someone without AWS access. It is worth
knowing it is a one-line endpoint change should that situation change.
