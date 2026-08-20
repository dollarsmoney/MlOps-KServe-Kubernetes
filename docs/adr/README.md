# Architecture Decision Records

Short documents capturing decisions that had **real alternatives**. Each records the context,
the decision, and — most importantly — what it costs, so a future reader can tell whether the
reasoning still holds.

Decisions with no genuine alternative (using git, using Docker) are not recorded here; they
would be noise.

| # | Decision | Status |
|---|---|---|
| [0001](0001-kserve-serverless-mode.md) | KServe in Serverless mode, not RawDeployment | Accepted |
| [0002](0002-pin-python-311.md) | Pin Python to 3.11 | Accepted |
| [0003](0003-s3-over-minio.md) | Real S3 rather than in-cluster MinIO | Accepted |
| [0004](0004-kafka-kraft-single-broker.md) | Kafka KRaft mode, single broker locally | Accepted |
| [0005](0005-two-stage-retrieval-ranking.md) | Two-stage retrieve-then-rank, multi-task ranker | Accepted |

## Format

```markdown
# ADR-NNNN: Title

- Status: Proposed | Accepted | Superseded by ADR-XXXX
- Date: YYYY-MM-DD
- Affects: which phases/components

## Context     — the forces at play, including what made this non-obvious
## Decision    — what we chose
## Consequences — what we gained, what we paid, what we rejected and why
```

Records are immutable once accepted. A reversal gets a **new** ADR that supersedes the old one,
so the history of reasoning stays intact.
