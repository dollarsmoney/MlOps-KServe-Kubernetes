# ADR-0004: Kafka in KRaft mode, single broker locally

- **Status:** Accepted
- **Date:** 2026-08-20
- **Affects:** Phase 8

## Context

Kafka historically required **ZooKeeper** for cluster metadata, meaning two distributed
systems to deploy, tune, and debug. **KRaft** mode replaces ZooKeeper with a Raft quorum
inside Kafka itself, and is the supported default in current Kafka versions — ZooKeeper mode
is removed in Kafka 4.x.

Separately: how many brokers locally? Production Kafka runs three or more so that
`replication.factor=3` survives a broker loss. On an 11 GB minikube also hosting Knative,
Istio, Postgres, Redis, Prometheus, Grafana, MLflow, and the application services, three
brokers is not affordable — and would not teach anything the single-broker setup does not.

## Decision

**KRaft mode**, no ZooKeeper. **One broker** locally with `replication.factor=1`, deployed as
a `StatefulSet` with a PVC. Six topics, each with **3 partitions**, keyed by `user_id`.

Replication factor and broker count are Helm values, so the same chart deploys a 3-broker,
RF=3 cluster on EKS without template changes.

## Consequences

**Gained**

- One system to operate instead of two; matches how Kafka is deployed today.
- Fits the memory budget alongside everything else.
- 3 partitions per topic — even on one broker — makes partitioning, consumer-group rebalancing,
  and per-partition ordering *observable*. You can run two consumers in a group and watch
  partitions get reassigned. That is the lesson; extra brokers would not add to it.

**Paid**

- No fault tolerance locally: the broker dying loses unreplicated data. Acceptable for
  development, and it makes the *reason* production uses RF=3 concrete rather than abstract.
- Local throughput is not representative. We are not benchmarking.

**Note on partition count:** 3 partitions caps consumer-group parallelism at 3 consumers.
Partitions can be added later, but doing so **changes key-to-partition mapping** and therefore
breaks per-user ordering guarantees for existing keys — which is precisely why partition count
deserves thought up front rather than being defaulted to 1.
