# ADR-0001: Install KServe in Serverless mode, not RawDeployment

- **Status:** Accepted
- **Date:** 2026-08-20
- **Affects:** Phase 6 (KServe install), Phase 12 (canary rollout)

## Context

KServe supports two deployment modes:

- **RawDeployment** — plain Kubernetes `Deployment` + `Service` + HPA. Light, no extra
  operators, easy to reason about.
- **Serverless** — Knative Serving (plus a networking layer, Istio here). Adds revisions,
  request-concurrency autoscaling, scale-to-zero, and traffic splitting.

RawDeployment is the obvious first choice on a laptop: fewer moving parts and roughly 1 GB
less memory. We very nearly chose it.

The problem is Phase 12. Progressive rollout — 10% → 50% → 100% — is a core requirement of
this project, and in KServe it is expressed as:

```yaml
spec:
  predictor:
    canaryTrafficPercent: 10
```

**In RawDeployment mode this field is silently ignored.** No error, no warning, no status
condition. The InferenceService reports `Ready`, the manifest says 10%, and 100% of traffic
goes to the new model. Traffic splitting is implemented through Knative revision weights,
which do not exist in RawDeployment. Support via Gateway API `HTTPRoute` weights is an open
feature request ([kserve#5335](https://github.com/kserve/kserve/issues/5335)), not shipped.

A silent failure is far worse than an unsupported one: you would believe you had a safe canary
while running an unvalidated model against every user.

## Decision

Install KServe in **Serverless mode** — cert-manager + Istio + Knative Serving + KServe — from
Phase 6 onward, on both minikube and EKS.

## Consequences

**Gained**

- `canaryTrafficPercent` works as documented; Phase 12 teaches the real mechanism.
- Knative **revisions** are immutable snapshots, so rollback is a weight change (seconds), not
  a redeploy.
- Autoscaling on **request concurrency**, which is the correct signal for inference, rather
  than on CPU.
- Scale-to-zero for idle experimental models — useful once several versions coexist.

**Paid**

- ~1 GB extra cluster memory and three additional operators to install and understand.
- More components in the request path to debug: Istio gateway → Knative route → queue-proxy →
  our container. Phase 6 walks this path explicitly rather than treating it as a black box.
- minikube must be sized at `--cpus=6 --memory=11g` (host has 8 CPU / 15.7 GB).

**Rejected alternative:** RawDeployment plus a hand-written Istio `VirtualService` for
weighted splitting. It works, and it is arguably more transparent, but it still requires
Istio — so most of the resource saving disappears — while diverging from how KServe is
documented and operated in practice. We would be teaching a workaround instead of the tool.

## Revisit if

KServe ships `canaryTrafficPercent` for RawDeployment via Gateway API. RawDeployment would
then be lighter with equivalent capability.

## References

- [KServe canary rollout strategy](https://kserve.github.io/website/docs/model-serving/predictive-inference/rollout-strategies/canary)
- [kserve#5335 — canaryTrafficPercent for RawDeployment](https://github.com/kserve/kserve/issues/5335)
