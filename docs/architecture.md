# Architecture

Deep reference for the platform. The [README](../README.md) gives the overview; this document
explains *how each component works* and *why it exists*. Decisions with real alternatives are
recorded separately in [`adr/`](adr/).

---

## 1. Design principles

1. **Every component has one job.** If two components could own a responsibility, exactly one
   does. The "explicitly not its job" column in the README is load-bearing.
2. **The request path is a latency budget, not a wish.** ~50 ms end to end. Anything that
   cannot meet its slice moves off the request path (precomputed into Redis, or done async
   via Kafka).
3. **Offline and online must share definitions.** One `ml/features/` module, two execution
   contexts. Duplicated feature logic is training/serving skew waiting to happen.
4. **Nothing auto-promotes to production.** Every model passes a quality gate and a canary.
5. **State is rebuildable.** Redis can be reconstructed from Kafka + Postgres. Losing the
   cache is a performance incident, not a data-loss incident.

---

## 2. Serving components

### 2.1 API Gateway (`apps/api-gateway`)

FastAPI behind a Kubernetes Ingress. Owns authentication, rate limiting, request IDs, and
routing to the two backend services. It exists so that cross-cutting concerns live in one
place rather than being reimplemented in each service, and so the public surface is a single
stable contract while services behind it are free to change.

Kubernetes resources: `Deployment`, `Service` (ClusterIP), `Ingress`, `HorizontalPodAutoscaler`,
`ConfigMap`, `ServiceAccount`.

### 2.2 Recommendation Service (`apps/recommendation-service`)

The orchestrator, and the most interesting service in the system. Per request:

1. **Load user context** from Redis — interests vector, recent video IDs, followed creators.
2. **Generate candidates** by running the six strategies (concurrently), then union + dedupe.
   A cap per strategy prevents any one source from dominating the pool.
3. **Assemble features** for every candidate, using the shared `ml/features` definitions.
4. **Score** — one batched request to KServe with all ~1000 candidates. One batched call, not
   1000 calls: network round-trips dominate, and the model's matrix multiplications are far
   more efficient batched.
5. **Blend and rank** using the configurable weights from a ConfigMap.
6. **Apply business rules** — creator diversity caps, already-seen filtering, freshness floor.

Note what this service does *not* do: it does not contain the model. Swapping the ranker is a
KServe change; swapping candidate generation is a service change. That boundary is why KServe
is worth the operational cost — see [ADR-0001](adr/0001-kserve-serverless-mode.md).

**Degradation:** if KServe is unavailable, the service returns trending + followed-creator
candidates in heuristic order rather than erroring. A worse feed beats no feed, and this makes
model deployment failures non-catastrophic.

### 2.3 Event Service (`apps/event-service`)

Accepts interaction events, validates them, and produces to Kafka. Deliberately thin — it does
no aggregation and writes to no database, so it can absorb traffic spikes and stay available
when downstream systems are slow. It acknowledges once Kafka accepts the write.

Events are keyed by `user_id`, which guarantees all of one user's events land on the same
partition and are therefore consumed **in order**. This matters: "watched then liked" and
"liked then watched" are different behavioural signals.

### 2.4 KServe InferenceService (`kserve/`)

Runs in **Serverless mode** on Knative — see [ADR-0001](adr/0001-kserve-serverless-mode.md).

What KServe actually does for us, concretely — this is the "no magic" part:

```
POST /v1/models/recommendation-ranker:predict
        |
        v
[Istio Ingress Gateway]        TLS termination, routing by Host header
        |
        v
[Knative Route]                splits traffic across revisions by weight
        |                      ← this is where canary 90/10 is enforced
        v
[Knative Revision → Pod]       an immutable snapshot of config + image
        |
        +-- [queue-proxy container]   concurrency accounting, metrics,
        |                             the signal that drives autoscaling
        |
        +-- [kserve-container]        our Python predictor
                 |
                 +-- storage-initializer (initContainer)
                 |      downloaded the model from S3 into a shared
                 |      volume before the container ever started
                 |
                 +-- Model.load()     runs once at startup
                 +-- Model.predict()  runs per request
        |
        v
Response: scored candidates
```

Each piece earns its place:

- **storage-initializer** — model artifacts stay out of the container image. The same image
  serves model v3 or v7 depending on `storageUri`. Retraining does not require a rebuild.
- **queue-proxy** — enforces per-pod concurrency and emits the metrics the autoscaler consumes.
  It is why KServe can scale on *concurrent requests* rather than CPU, which is the right
  signal for inference.
- **Knative Revision** — every spec change creates a new immutable revision. Rollback is
  re-pointing traffic weights at the old revision, not a redeploy. This is the mechanism that
  makes Phase 12's rollback fast and safe.
- **Knative Route** — owns the traffic split. `canaryTrafficPercent: 10` becomes revision
  weights here.

**The prediction path inside the container:** `predict()` receives a user ID and candidate
IDs, assembles or receives their features, runs one batched forward pass producing six
probabilities per candidate, applies the configured weights, sorts, and returns
`[{video_id, score}]` in descending order. The model returns *calibrated probabilities*; the
service applies *business weights*. Keeping those two separate is what allows product strategy
to change without retraining.

---

## 3. Data components

### 3.1 PostgreSQL — application truth

Tables: `users`, `creators`, `videos`, `video_metadata`, `follows`, `interactions`.

Postgres holds facts that must be correct, transactional, and durable. It is **not** on the
hot path for feature lookups — a recommendation request needing five Postgres queries at
5–20 ms each would blow the entire latency budget before the model even runs.

`interactions` is written to by the Kafka archiver, not by the request path, and serves
analytics and backfills. The training set comes from S3 Parquet, not from this table.

### 3.2 Redis — the online feature store

| Key | Type | Contents |
|---|---|---|
| `user:{id}:recent_videos` | List | Last N watched video IDs (dedupe + recency features) |
| `user:{id}:interests` | Hash | category → affinity score |
| `user:{id}:followed_creators` | Set | Creator IDs |
| `user:{id}:features` | Hash | Precomputed aggregates: avg watch time, completion rate, … |
| `video:{id}:trending_score` | Sorted Set member | Global trending leaderboard |
| `video:{id}:features` | Hash | Engagement aggregates |

**Why not query Postgres for each request?** Three reasons, in order of importance:

1. **Latency.** Redis serves point lookups in well under a millisecond from memory; Postgres
   costs milliseconds per query with connection and planner overhead. Step 2–4 of the request
   path would go from ~16 ms to well over 100 ms.
2. **Load shape.** Recommendation traffic is read-dominated and hot-key skewed. Hammering the
   transactional database with that pattern degrades the writes the product depends on.
3. **Precomputation.** `user:{id}:interests` is not a row anywhere — it is an aggregate over
   the user's history, maintained incrementally by the Kafka consumer. Recomputing it per
   request would be absurd; storing it in Postgres would make Postgres a cache with worse
   performance characteristics than a cache.

Redis holds **derived** state exclusively. Every key is rebuildable by replaying Kafka or
re-aggregating Postgres, so it can be flushed without data loss.

### 3.3 Kafka — the event backbone

Single broker in **KRaft** mode locally (no ZooKeeper) — see
[ADR-0004](adr/0004-kafka-kraft-single-broker.md).

**Topics:** `video.views` · `video.likes` · `video.comments` · `video.shares` ·
`video.skips` · `user.follows`

The concepts, concretely as used here:

- **Producer** — the event-service. Writes an event to a topic, choosing a partition via the
  key (`user_id`).
- **Topic** — a named, append-only log. Separate topics per event type let consumers subscribe
  only to what they need and let retention be tuned per type.
- **Partition** — the unit of parallelism and of ordering. Ordering is guaranteed *within* a
  partition only. Keying by `user_id` puts each user's events in one partition, so per-user
  order holds while different users process in parallel.
- **Consumer group** — a set of consumers sharing the work of a topic; each partition is
  assigned to exactly one member. Add a consumer, get more parallelism (up to the partition
  count). Crucially, **each group tracks its own offsets**, so three groups read the same
  events independently at their own pace.
- **Offset** — a consumer group's position in a partition. Because Kafka retains events rather
  than deleting on read, resetting an offset **replays history** — which is how we rebuild
  Redis from scratch or backfill a new feature.

Our three consumer groups:

| Group | Reads | Writes | Purpose |
|---|---|---|---|
| `raw-archiver` | all topics | S3 Parquet | Training data — the source of truth for the ML pipeline |
| `feature-updater` | all topics | Redis | Keeps online features fresh within seconds |
| `metrics-aggregator` | all topics | Prometheus | Live CTR, watch time, completion rate |

The archiver falling behind must not delay the feature updater. Independent consumer groups
give exactly that isolation — the reason Kafka is here instead of the event-service writing
directly to Redis and S3.

### 3.4 S3 — object storage

Three prefixes, three roles: `raw/` (archived events), the DVC remote (content-addressed
dataset and model blobs), and MLflow artifacts. Immutable and versioned; never read on the
request path.

---

## 4. The ML pipeline

### 4.1 What DVC versions vs. what Git versions

The most common point of confusion, so precisely:

| Stored in **Git** | Stored in **DVC/S3** |
|---|---|
| Source code | The actual bytes of datasets |
| `dvc.yaml` — stage definitions | Model weight files |
| `dvc.lock` — the **hashes** of every input and output | Intermediate pipeline outputs |
| `params.yaml` | |
| `*.dvc` pointer files (a few hundred bytes) | |

A `.dvc` file is a small YAML pointer containing an MD5 hash, size, and path. Git tracks the
pointer; S3 stores the content, addressed by that hash. This is why the repo stays small
while datasets grow to gigabytes, and why `git checkout <old-commit> && dvc checkout`
restores the exact data that commit was built with.

**Reproducing an old model** — the whole reason for this machinery:

```bash
git checkout <commit>   # restores code, dvc.lock, params.yaml
dvc checkout            # restores the exact data those hashes name
dvc repro               # rebuilds; identical hashes ⇒ nothing to recompute
```

The MLflow run for that model records the same dataset hash, closing the loop from a deployed
model back to the exact bytes it was trained on.

### 4.2 Pipeline stages (`dvc.yaml`)

```
raw data → preprocess → feature engineering → train → evaluate
```

Each stage declares `deps`, `params`, `outs`, and `metrics`. DVC hashes those inputs, so
`dvc repro` reruns a stage only when something it actually depends on changed. Editing a
training hyperparameter in `params.yaml` reruns training and evaluation but skips preprocessing
and feature engineering.

### 4.3 MLflow: four parts people conflate

| Part | What it is | Ours |
|---|---|---|
| **Tracking server** | The API/UI that receives runs | Deployment in the cluster |
| **Backend store** | Database of runs, params, metrics, tags | PostgreSQL |
| **Artifact store** | Where files go — models, plots, encoders | S3 |
| **Model registry** | Named models, versions, stage transitions | Uses the same backend store |

Metrics logged per run: Precision@K, Recall@K, NDCG@K, MAP@K, simulated CTR, watch-time MAE.
Tags include the **DVC dataset hash**, the feature version, and the git commit — enough to
answer "what produced this production model?" from a single run page.

### 4.4 Model registry and promotion

```
RecommendationRanker
    v1 → Archived
    v2 → Production      ← currently serving
    v3 → Staging         ← passed the offline gate, awaiting canary
    v4 → Development     ← latest experiment
```

**Promotion (Phase 11):** a new run is compared against the current Production model on the
same evaluation split. It advances to Staging only if it wins on NDCG@10 by a stated margin
*and* meets the p99 latency budget. Otherwise it is rejected with a recorded reason. Offline
wins are necessary but never sufficient — hence the canary.

**Rollback (Phase 12):** re-point Knative traffic weights at the previous revision (seconds),
then transition the registry stage back. The model artifact was never deleted, and the
InferenceService manifest for the old version is still in git.

---

## 5. Monitoring: two different disciplines

**Infrastructure monitoring** answers *"is the system running?"* — CPU, memory, request rate,
p50/p95/p99 latency, error rate, pod restarts, replica count. Failures are loud and immediate.

**ML monitoring** answers *"is the system still right?"* — CTR, average watch time, completion
rate, skip rate, like/share rate, NDCG, and which model version served each request. Failures
are **silent**: every pod is healthy, every request returns 200 in 30 ms, and the
recommendations have been quietly getting worse for a week. No infrastructure signal catches
that. This is why both dashboards exist.

Four degradation modes, distinguished because they need different responses:

| Mode | What shifts | Example | Response |
|---|---|---|---|
| **Data drift** | Input distribution `P(x)` | New country launches; device mix shifts | Retrain on recent data |
| **Feature drift** | A single feature's distribution | `avg_watch_time` jumps — often a bug, not behaviour | Investigate the pipeline *first* |
| **Prediction drift** | Output distribution `P(ŷ)` | Mean `P(like)` drops 30% with no input change | Check for a serving bug or skew |
| **Model degradation** | The relationship `P(y|x)` | Metrics fall while inputs look normal | Retrain; consider label shift |

Detection: PSI and KS tests comparing a rolling production window against the training
distribution, run as a scheduled job, exported to Prometheus, alertable in Grafana.
Prediction drift is the fastest signal — it needs no ground-truth labels, which arrive hours
or days late.

---

## 6. Kubernetes resources, and why each exists

| Resource | Why |
|---|---|
| **Namespace** | Isolation and quota boundary: `recsys`, `kserve`, `monitoring`, `data` |
| **Deployment** | Declarative replica management + rolling updates for stateless services |
| **StatefulSet** | Postgres/Kafka: stable identity and per-pod persistent storage |
| **Service** | Stable virtual IP + DNS in front of changing pod IPs |
| **Ingress** | Single external entry point, TLS termination |
| **ConfigMap** | Non-secret config — including the ranking weights, so they change without a rebuild |
| **Secret** | Credentials, mounted as env or volume; never baked into images |
| **ServiceAccount** | Pod identity — for RBAC in-cluster, and for IRSA on EKS |
| **Role / RoleBinding** | Least privilege: the recommendation service can read its ConfigMap, nothing more |
| **Resource requests** | What the scheduler reserves — too low and pods land on saturated nodes |
| **Resource limits** | The cap — prevents one pod starving its neighbours (memory over-limit = OOMKill) |
| **Liveness probe** | "Is it alive?" Failure ⇒ restart. Wrong config here causes restart loops |
| **Readiness probe** | "Can it serve?" Failure ⇒ removed from the Service. Critical during model load |
| **Startup probe** | Protects slow starts (model loading) from being killed by the liveness probe |
| **HPA** | Scale on demand; recommendation traffic is strongly diurnal |
| **PodDisruptionBudget** | Keeps a minimum available during node drains |
| **NetworkPolicy** | Default-deny; only declared flows allowed. Nothing but the recommendation service reaches the model |

---

## 7. AWS and credential handling

Terraform provisions VPC, EKS, ECR, S3, and IAM. The important decision is how pods reach S3.

**Not** AWS access keys in a Kubernetes Secret: long-lived, manually rotated, visible to
anyone with `get secrets` in the namespace, and identical across every workload — no way to
tell which pod used them.

Instead **IRSA** (IAM Roles for Service Accounts) — or EKS Pod Identity. The cluster's OIDC
provider is registered as an IAM identity provider; a ServiceAccount is annotated with a role
ARN; pods using it receive a projected OIDC token that is exchanged for **short-lived,
automatically rotated** credentials. The result: per-workload least privilege, no static
secrets anywhere, and CloudTrail entries attributable to a specific service account.

---

## 8. Failure modes and their handling

| Failure | Handling |
|---|---|
| KServe unavailable | Recommendation service degrades to heuristic ranking |
| Redis unavailable | Fall back to Postgres with a reduced candidate pool; latency rises, service survives |
| Kafka unavailable | Event service returns 503; clients buffer and retry. No data written to a half-consistent state |
| Postgres unavailable | Recommendations continue from Redis; writes fail |
| Bad model deployed | Canary catches it at 10% traffic; automatic rollback on threshold breach |
| Data pipeline produces garbage | Validation stage rejects before training; the quality gate rejects before promotion |
