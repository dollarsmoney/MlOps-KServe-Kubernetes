# Short-Video Recommendation Platform — MLOps Reference Build

A production-style, end-to-end recommendation system: it ingests user interaction events,
versions the resulting datasets, trains a multi-task ranking model, gates it on quality,
serves it on Kubernetes through KServe, canaries new versions, and monitors both the
infrastructure *and* the model.

This is an educational approximation of how short-video platforms structure recommendations.
It is **not** a reproduction of any company's proprietary algorithm — the public record on
those systems is thin, and pretending otherwise would teach the wrong things. What it does
reproduce faithfully is the *engineering shape*: two-stage retrieve-then-rank, multi-objective
scoring, and the MLOps loop around it.

> **Status:** Phase 0 complete (architecture + repo skeleton). No application code yet.
> See the [phase checklist](#phase-checklist).

---

## Table of contents

- [The lifecycle in one picture](#the-lifecycle-in-one-picture)
- [Serving architecture](#serving-architecture)
- [The recommendation algorithm](#the-recommendation-algorithm)
- [ML pipeline architecture](#ml-pipeline-architecture)
- [Technology decisions](#technology-decisions)
- [Where data lives](#where-data-lives)
- [Repository layout](#repository-layout)
- [Quickstart](#quickstart)
- [Phase checklist](#phase-checklist)

---

## The lifecycle in one picture

Every component in this repo exists to serve one loop. The loop closes — recommendations
change user behaviour, which becomes the next training set:

```
User interaction
      ↓
Event collection  (Event API)
      ↓
Kafka             (durable, replayable event log)
      ↓
Data              (raw Parquet in S3)
      ↓
DVC               (immutable, hashed dataset version)
      ↓
Feature engineering  (point-in-time correct)
      ↓
Training          (multi-task ranker)
      ↓
MLflow            (params, metrics, artifacts)
      ↓
Model Registry    (Dev → Staging → Production)
      ↓
Model validation  (quality gate vs. current production model)
      ↓
Docker → ECR
      ↓
Kubernetes → KServe
      ↓
Real-time inference
      ↓
Recommendation
      ↓
User interaction  ← the loop closes here
      ↓
New training data → Retraining
```

The feedback loop is also the system's biggest hazard: the model influences the data it will
next be trained on. That is why the design includes an **exploration** candidate source and
why we measure a popularity baseline on every evaluation — without both, the model quietly
learns to justify its own past decisions.

---

## Serving architecture

```
Mobile/Web Client
       |
       v
   API Gateway  (FastAPI + Kubernetes Ingress)
       |
       +---------------------------------+
       |                                 |
       v                                 v
Recommendation API                   Event API
       |                                 |
       v                                 v
Recommendation Service              Kafka  (KRaft, single broker)
   |     |      |                         |
   |     |      |                    +----+-----------------+
   |     |      |                    |         |            |
   |     |      |                    v         v            v
   |     |      |              raw-archiver  feature-   metrics-
   |     |      |                   |        updater    aggregator
   |     |      |                   v          |            |
   |     |      |                  S3          |            v
   |     |      |                              |       Prometheus
   |     |      +-- Redis  <-------------------+
   |     |             user:{id}:recent_videos
   |     |             user:{id}:interests
   |     |             user:{id}:followed_creators
   |     |             video:{id}:trending_score
   |     |
   |     +-- PostgreSQL
   |            users · videos · creators · follows · video_metadata · interactions
   |
   v
KServe InferenceService
       |
       v
Multi-task MLP  →  P(watch) P(complete) P(like) P(share) P(follow) P(skip)
       |
       v
Weighted ranking score  →  sorted video list
```

**Read path (a recommendation request), with the latency budget:**

| Step | Where | Budget |
|---|---|---|
| 1. Request hits API Gateway, auth + routing | api-gateway | ~2 ms |
| 2. Load user context (interests, recent, follows) | **Redis** | ~1 ms |
| 3. Candidate generation — 6 strategies, unioned & deduped | Redis + Postgres | ~10 ms |
| 4. Feature assembly for ~1000 candidates | Redis + in-process | ~5 ms |
| 5. Batch score all candidates | **KServe** | ~30 ms |
| 6. Blend 6 probabilities → rank → diversity rules → top 20 | recommendation-service | ~2 ms |
| **Total** | | **~50 ms** |

**Write path (an interaction event):** client → Event API → Kafka (partitioned by `user_id`,
so one user's events stay ordered) → three independent consumer groups, each with its own
offset: archive to S3 for training, update Redis for online features, aggregate to Prometheus
for the ML dashboards. Adding a fourth consumer later requires changing nothing upstream —
that decoupling is the entire reason Kafka is here rather than a direct database write.

---

## The recommendation algorithm

### Why not just recommend popular videos?

A popularity ranking is **one global ordering shown to everyone**. It fails in four ways this
project makes measurable:

1. **No personalization.** A cooking enthusiast and a skateboarder see the same feed.
2. **Rich-get-richer.** Popular videos get shown, so they get more engagement, so they rank
   higher. New creators never surface, and the catalogue ossifies.
3. **No multi-objective tradeoff.** A clickbait video may have a high `P(watch)` *and* a high
   `P(skip)` and a low `P(complete)`. Popularity cannot express "started often, finished never".
   A learned ranker with separate heads can.
4. **No context.** Popularity ignores time of day, device, what the user just watched, and
   whether they already follow the creator.

Phase 4 quantifies this: we compute NDCG@10 for a popularity baseline and for the ranker on
the identical evaluation split. The baseline is not a straw man — it is a genuinely strong
starting point, and beating it is the bar the model has to clear.

### Two-stage: retrieve, then rank

Scoring ten million videos per request with a neural network is impossible inside a 50 ms
budget. So the work is split — a cheap, high-recall stage narrows the field, and an expensive,
high-precision stage orders what survives:

```
   ~10,000,000 videos
           |
           v
   Candidate Generation        cheap · high recall · ~10 ms
   (lookups and precomputed lists — no model inference)
           |
           v
      ~1,000 candidates
           |
           v
   Ranking Model               expensive · high precision · ~30 ms
   (one batched forward pass over all candidates)
           |
           v
      Top 20 videos
```

**Candidate sources** — each is a small, independently testable strategy; results are unioned
and deduplicated:

| Source | Signal | Why it's there |
|---|---|---|
| Followed creators | `user:{id}:followed_creators` | Explicit user intent, highest precision |
| Category affinity | `user:{id}:interests` | Generalizes taste beyond specific creators |
| Item-item collaborative filtering | "users who watched X also watched Y" | Finds taste neighbours the categories miss |
| Trending | `video:{id}:trending_score` | Fresh, culturally relevant content |
| Recency | new uploads in affine categories | Solves the item cold-start problem |
| **Exploration** | random sample from the tail | Breaks the feedback loop; generates training signal for unseen items |

Recall at this stage matters far more than precision: a video the retriever never proposes can
*never* be recommended, no matter how good the ranker is.

### Ranking: multi-task, because engagement isn't one number

The ranker is a shared-bottom MLP with six sigmoid heads. One shared representation of
(user, video, creator, context) feeds six task-specific heads:

```
  user_id ──┐
 video_id ──┤   embeddings
creator_id ─┤       +          ┌──> P(watch)
 category ──┤   dense feats    ├──> P(complete)
            └──> shared MLP ───┼──> P(like)
                (256→128→64)   ├──> P(share)
                               ├──> P(follow)
                               └──> P(skip)
```

Why shared-bottom rather than six separate models: the tasks are correlated, so they act as
mutual regularizers, and rare signals (share, follow) borrow representational strength from
abundant ones (watch, skip). It is also one artifact to version, deploy, and roll back
instead of six.

**Features** span four groups — user (`average_watch_time`, `completion_rate`, `like_rate`,
`skip_rate`, `watch_history`), video (`video_age`, `video_category`, `video_engagement`,
`video_duration`), creator (`creator_followers`, historical engagement), and the cross
features that carry most of the personalization signal (`user_category_affinity`,
`creator_affinity`). Feature engineering is **point-in-time correct**: a training row
timestamped `T` may only use aggregates computed from events strictly before `T`. Violating
this is the single most common way recommendation projects produce great offline metrics and
a model that fails in production.

### Blending the six probabilities

```
ranking_score =
     0.30 * P(watch)
   + 0.25 * P(complete)
   + 0.20 * P(like)
   + 0.15 * P(share)
   + 0.10 * P(follow)
   - 0.25 * P(skip)
```

These weights are **configuration, not code**. They live in `params.yaml`, ship to the cluster
as a ConfigMap, and can be retuned without retraining or redeploying the model — the network
outputs calibrated probabilities; the weights encode *product strategy*. Shifting the business
toward retention over virality is a ConfigMap edit, not an ML project. The negative weight on
`P(skip)` is what lets the system actively demote content it predicts users will bail on.

---

## ML pipeline architecture

```
Kafka events
     |
     v
Raw event storage (Parquet on S3)
     |
     v
DVC  ──── content-hashed dataset version
     |
     v
Preprocess          ┐
     |              │
     v              │  dvc.yaml stages — each with declared
Feature engineering │  deps, params, outs and metrics, so
     |              │  `dvc repro` reruns only what changed
     v              │
Training            │
     |              │
     v              ┘
Evaluate
     |
     v
MLflow ──┬── Experiments (one run per training, tagged with the dataset hash)
         ├── Metrics     (Precision@K, Recall@K, NDCG@K, MAP@K, CTR sim, watch-time MAE)
         └── Artifacts   (model weights, feature spec, encoders → S3)
     |
     v
Model Registry ── Development → Staging → Production
     |
     v
Quality gate ──── worse than production? → REJECT (with a reason)
     |            better on NDCG@10 *and* within latency budget? → promote
     v
Docker → ECR → Kubernetes → KServe → canary 10% → 50% → 100%
     |
     v
Production inference
```

Nothing here auto-deploys. A newly trained model that beats production offline is promoted to
**Staging**, not Production; reaching Production requires passing the canary in Phase 12. See
[`docs/architecture.md`](docs/architecture.md) for the full reasoning.

---

## Technology decisions

Each technology earns its place by doing **one job**. Equally important is what each one is
*not* allowed to do — that constraint is what keeps the architecture from collapsing into a
tangle where every component talks to every other.

| Technology | Its one job | Explicitly not its job |
|---|---|---|
| **Kafka** | Decouple event ingestion from every consumer; durable, replayable log | Not a database; never read synchronously on the request path |
| **PostgreSQL** | Application truth — users, videos, creators, follows | Not the online feature store; not training storage |
| **Redis** | Sub-millisecond online features and candidate lists | Not durable truth — fully rebuildable from Kafka + Postgres |
| **S3** | Immutable artifacts — datasets, model files, MLflow artifacts | Not queried live |
| **DVC** | Version large files; make the pipeline reproducible | Does not version code — git does |
| **MLflow** | Experiment history, metrics, model registry, stage transitions | Not a serving engine |
| **KServe** | Model serving — autoscaling, canary, v1/v2 protocol, health checks | Not business logic — candidate generation stays in our service |
| **Docker** | Identical runtime from laptop to EKS | Not a build system |
| **Kubernetes** | Scheduling, healing, scaling, service discovery, secrets | Not a substitute for application design |
| **Helm** | One versioned, parameterized, rollback-able release | Not for installing the KServe/Knative operators themselves |
| **Prometheus + Grafana** | Infra *and* ML metrics under one query language | Not per-request debugging — that's logs |
| **GitHub Actions** | CI, the ML pipeline, and CD triggers | Not a long-running training scheduler |
| **Terraform** | AWS infra as code — VPC, EKS, ECR, S3, IAM/IRSA | Not Kubernetes app resources — Helm owns those |

Five decisions were non-obvious enough to write down properly, with their alternatives and
consequences, in [`docs/adr/`](docs/adr/):

1. [KServe in Serverless mode, not RawDeployment](docs/adr/0001-kserve-serverless-mode.md) — because `canaryTrafficPercent` is *silently ignored* in RawDeployment
2. [Pin Python to 3.11](docs/adr/0002-pin-python-311.md) — the `kserve` SDK does not support 3.13
3. [Real S3 instead of MinIO](docs/adr/0003-s3-over-minio.md)
4. [Kafka in KRaft mode, single broker](docs/adr/0004-kafka-kraft-single-broker.md)
5. [Two-stage retrieve-then-rank](docs/adr/0005-two-stage-retrieval-ranking.md)

---

## Where data lives

"Just put it in the database" is where most ML systems go wrong. Five distinct storage roles,
five different access patterns:

| Role | System | Mutability | Access pattern | Example |
|---|---|---|---|---|
| **Application database** | PostgreSQL | Mutable, current state | Transactional reads/writes | "Does user 123 follow creator 45?" |
| **Feature storage — online** | Redis | Latest value, TTL'd | Point lookup, sub-ms, on the request path | `user:123:interests` |
| **Feature storage — offline** | Parquet on S3 | Immutable, point-in-time | Bulk scan for training | All features as of 2026-08-01 |
| **Training data** | DVC → S3 | Immutable, content-hashed | Read once per training run | `dataset v3 = a1b2c3...` |
| **Model registry** | MLflow (Postgres + S3) | Append-only, staged | "What's in production, and what data made it?" | `RecModel v7 → Production` |
| **Object storage** | S3 | Immutable blobs | The bytes under DVC, MLflow, models | `s3://…/models/v7/model.pt` |

The online and offline feature stores share **one set of feature definitions** in
`ml/features/`. Two implementations of the same logic is how training/serving skew gets in —
the model trains on one definition of `completion_rate` and serves on a subtly different one,
and nothing in the metrics reveals it.

---

## Repository layout

```
.
├── apps/                          # Runtime services (Phase 7)
│   ├── api-gateway/               #   auth, routing, rate limiting
│   ├── recommendation-service/    #   candidate generation + ranking orchestration
│   └── event-service/             #   interaction ingestion → Kafka
│
├── ml/                            # Everything model-related
│   ├── data/                      #   synthetic event generator (Phase 1)
│   ├── features/                  #   shared feature definitions — online + offline
│   ├── training/                  #   multi-task ranker (Phase 4)
│   ├── evaluation/                #   ranking metrics + baselines
│   └── inference/                 #   KServe predictor (Phase 5)
│
├── data/{raw,processed}/          # DVC-tracked, git-ignored
├── models/                        # DVC-tracked model artifacts
│
├── docker/                        # One Dockerfile per image
├── helm/recommendation-platform/  # The whole platform as one chart (Phase 9)
├── kserve/                        # InferenceService manifests (Phase 6)
├── kubernetes/                    # Cluster bootstrap: namespaces, operators, RBAC
├── terraform/                     # AWS: vpc · eks · ecr · s3 · iam (Phase 14)
├── monitoring/                    # Prometheus rules + Grafana dashboards (Phase 10)
│
├── .github/workflows/             # ci.yml · ml-pipeline.yml · cd.yml (Phase 13)
├── tests/{unit,integration}/
├── docs/                          # architecture.md · adr/ · runbooks/
├── scripts/                       # Cluster bootstrap and env checks
│
├── dvc.yaml                       # Pipeline definition (Phase 2)
├── params.yaml                    # All tunables, including the ranking weights
├── Makefile                       # Every command you need, discoverable via `make help`
└── pyproject.toml
```

---

## Quickstart

Nothing to run yet — Phase 0 is architecture only. From Phase 1 onward:

```bash
make help          # every available command, with descriptions
make check-env     # verify your local tooling matches what the phases assume
make venv          # create the Python 3.11 virtualenv
```

**Prerequisites** (checked by `make check-env`): Python 3.11, Docker, kubectl, Helm 3,
minikube, AWS CLI with credentials, and ~11 GB of RAM free for the local cluster from
Phase 6 onward.

---

## Phase checklist

Built incrementally. Each phase: explain the architecture → explain the technology choice →
write the code → run it → verify the expected output → a hands-on task → commit → push.

- [x] **Phase 0** — Architecture, repo skeleton, ADRs
- [ ] **Phase 1** — Synthetic event generator (realistic behavioural simulation)
- [ ] **Phase 2** — DVC pipeline + S3 remote
- [ ] **Phase 3** — Feature engineering + MLflow tracking, with ranking metrics
- [ ] **Phase 4** — Multi-task ranker vs. popularity baseline
- [ ] **Phase 5** — KServe predictor + Docker image
- [ ] **Phase 6** — minikube + Knative + KServe; first InferenceService
- [ ] **Phase 7** — PostgreSQL, Redis, and the three services on Kubernetes
- [ ] **Phase 8** — Kafka: topics, partitions, three consumer groups
- [ ] **Phase 9** — Helm chart for the whole platform
- [ ] **Phase 10** — Prometheus + Grafana; infra board, ML board, drift detection
- [ ] **Phase 11** — Retraining with a model quality gate
- [ ] **Phase 12** — Canary rollout 10% → 50% → 100%, and rollback
- [ ] **Phase 13** — GitHub Actions: CI, ML pipeline, CD
- [ ] **Phase 14** — Terraform: VPC, EKS, ECR, S3, IRSA
- [ ] **Phase 15** *(optional)* — Argo CD for GitOps

---

## License

MIT — see [LICENSE](LICENSE).
