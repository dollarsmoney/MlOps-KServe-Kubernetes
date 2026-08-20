# ADR-0005: Two-stage retrieve-then-rank with a multi-task ranker

- **Status:** Accepted
- **Date:** 2026-08-20
- **Affects:** Phases 4, 5, 7

## Context

Given a catalogue of ~10M videos and a ~50 ms latency budget, the system must produce a
personalized top-20 per request.

Scoring every video with a neural network per request is arithmetically impossible. Even at an
optimistic 1 µs per candidate, 10M candidates is 10 seconds. The catalogue must be narrowed by
something cheap before anything expensive runs.

A second question is the model's output shape. Engagement is not one number: watching,
completing, liking, sharing, following, and skipping are distinct behaviours that a product
weighs differently — and a video can score high on one and terribly on another. The classic
failure is optimizing a single "engagement" scalar and discovering the model has learned to
promote clickbait: high `P(watch)`, high `P(skip)`, low `P(complete)`.

## Decision

**Stage 1 — Candidate generation.** Six cheap strategies (followed creators, category
affinity, item-item collaborative filtering, trending, recency, exploration), unioned and
deduplicated, each capped, producing ~1000 candidates in ~10 ms. Lookups and precomputed
lists only — no model inference.

**Stage 2 — Ranking.** A shared-bottom MLP with embeddings for user/video/creator/category,
and **six sigmoid heads** producing `P(watch)`, `P(complete)`, `P(like)`, `P(share)`,
`P(follow)`, `P(skip)`. One batched forward pass over all candidates, ~30 ms.

**Blending.** A weighted sum over the six probabilities, with weights in `params.yaml` and
shipped as a ConfigMap — configuration, never code.

## Consequences

**Gained**

- The latency budget is achievable, with cost proportional to candidates rather than catalogue.
- Separate heads make tradeoffs explicit and tunable. The negative `P(skip)` weight actively
  demotes content the model expects users to bail on.
- Shared-bottom lets rare signals (share, follow) borrow representation from abundant ones
  (watch, skip), and yields **one** artifact to version, deploy, and roll back rather than six.
- Product strategy — retention vs. virality — becomes a ConfigMap edit, not a retraining
  project, because the model emits calibrated probabilities and the service applies business
  weights.
- The exploration candidate source deliberately injects content the model would not have
  chosen, generating training signal for unseen items and damping the self-reinforcing
  feedback loop.

**Paid**

- **Recall is capped by stage 1.** A video the retriever never proposes can never be
  recommended, regardless of ranker quality. Candidate-generation recall must be measured in
  its own right — a ranker cannot compensate for it, and this is where such systems most often
  underperform without anyone noticing.
- Two components to tune, evaluate, and monitor instead of one.
- Multi-task training needs per-head loss weighting; rare positives (follow, share) require
  weighted BCE or they get ignored by the optimizer.

**Rejected alternatives**

- **Single-objective ranker.** Simpler, but cannot express the clickbait tradeoff, and every
  product weighting change becomes a retraining cycle.
- **Six independent models.** No shared representation, no transfer to rare tasks, and six
  artifacts to version and serve in lockstep.
- **Learned two-tower retrieval with ANN search.** The most faithful to production short-video
  systems and a natural later extension, but it roughly doubles the ML surface area. Heuristic
  and collaborative-filtering retrieval teaches the two-stage *structure* — which is the point
  — at a fraction of the complexity. Revisit once Phases 1–14 are complete.
