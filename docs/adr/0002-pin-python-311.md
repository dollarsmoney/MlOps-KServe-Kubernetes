# ADR-0002: Pin Python to 3.11

- **Status:** Accepted
- **Date:** 2026-08-20
- **Affects:** Every virtualenv, every Docker image, CI

## Context

The development machine runs Python 3.13. The natural instinct is to use it.

The `kserve` Python SDK — which `ml/inference` must import to implement a custom predictor —
supports **up to Python 3.12**. Python 3.13 support is an open request
([kserve#4818](https://github.com/kserve/kserve/issues/4818)), not a release.

That alone rules out 3.13. Choosing between 3.11 and 3.12 then comes down to wheel
availability: this project pulls `torch`, `confluent-kafka`, `psycopg[binary]`, `dvc[s3]`, and
`mlflow`, several of which ship compiled extensions. 3.11 has the broadest, longest-tested
wheel coverage across that set, so no one spends an afternoon compiling `confluent-kafka` from
source.

## Decision

Pin **Python 3.11** everywhere: `requires-python = ">=3.11,<3.12"`, `python:3.11-slim` base
images, `python-version: "3.11"` in CI. The system 3.13 installation is left untouched — the
project uses an isolated `.venv`.

## Consequences

- One Python version across laptop, CI, and cluster. "Works on my machine" failures caused by
  interpreter differences are eliminated by construction.
- No 3.12/3.13 language features (they buy this project nothing).
- `make venv` requires a 3.11 interpreter to exist; `make check-env` verifies it and points to
  an installer if missing.
- Revisit when `kserve` supports 3.13 **and** the compiled dependencies have matching wheels.

## References

- [kserve#4818 — Python 3.13 support](https://github.com/kserve/kserve/issues/4818)
