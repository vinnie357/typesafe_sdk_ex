# Architecture decision records

These records hold the design decisions for this package, and every deliberate deviation from the JS SDK. They are internal notes for people who change the code. Users read [`README.md`](../../README.md).

A committed ADR is a decision. It stays mutable: amend it in the same PR as the code change, and date the amendment. The first PR review asked that the rationale for the port's divergences stay in the repository, because the ADRs are the only place those decisions are written down (https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5722393470).

Each ADR documents behavior the code has today. Where a decision has a known gap, the ADR says so and links the tracking issue. Planned work is not an ADR.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [0001](0001-port-js-sdk-as-reference.md) | Port the JS SDK v0.6.0 as the behavioral reference | Accepted | 2026-09-17; re-verified 2026-09-29 |
| [0002](0002-runtime-dependency-is-req-only.md) | Runtime dependency is Req only | Accepted | 2026-09-17; amended 2026-09-29 |
| [0003](0003-public-api-facade-and-tagged-tuples.md) | Public API is a facade returning tagged tuples | Accepted | 2026-09-17 |
| [0004](0004-configuration-resolution-and-option-validation.md) | Configuration resolution and option validation | Accepted; decision 7 has a known implementation gap (#10) | 2026-09-17 |
| [0005](0005-sdk-owned-request-settings-headers-and-body-decoding.md) | SDK-owned request settings, headers, and body decoding | Accepted | 2026-09-17; amended 2026-09-29 |
| [0006](0006-error-taxonomy.md) | Error taxonomy | Accepted | 2026-09-17 |
| [0007](0007-retry-policy-and-engine-on-req-retry.md) | Retry policy and engine on Req's `:retry` | Accepted | 2026-09-29 |
| [0008](0008-timeouts-are-not-retried-by-default.md) | Timeouts are not retried by default | Accepted | 2026-09-29 |
| [0009](0009-retry-after-parsing.md) | Retry-After parsing | Accepted | 2026-09-29 |
| [0010](0010-per-attempt-timeout-on-req-receive-timeout.md) | Per-attempt timeout on Req `receive_timeout` | Accepted | 2026-09-17; amended 2026-09-29 |
| [0011](0011-question-builders-and-pre-send-validation.md) | Question builders and pre-send request validation | Accepted | 2026-09-17 |
| [0012](0012-test-seams-without-mocking-libraries.md) | Test seams without mocking libraries | Accepted | 2026-09-17; amended 2026-09-29 |

## Open work that touches these decisions

- Hardening `req_options` (ADR 0005): https://github.com/vinnie357/typesafe_sdk_ex/issues/7
- The v0.2.0 release gate, including the README audit: https://github.com/vinnie357/typesafe_sdk_ex/issues/8
- Gaps found while writing the ADRs (empty-string error fields, JSON `null` error body, stale `Timeout` moduledoc, blank `api_key` fall-through, non-keyword call options that raise; ADRs 0003, 0004, 0006, 0011): https://github.com/vinnie357/typesafe_sdk_ex/issues/10

## Citation conventions

- `path:line` names a line in the JS repository `typesafe-ai/typesafe-sdk-js` at commit `66880ccded6cb642dc1809620c2b108c33730214`, under `src/` or `test/` as the file name implies. Example: `retry.ts:38-49` is `src/retry.ts`, and `reliability.test.ts:51-73` is `test/reliability.test.ts`.
- `req@0.7.4 <file>:line`, `finch@0.24.0 <file>:line`, and `mint@1.11.0 <file>:line` name a line in the dependency versions locked in `mix.lock`. A bare `lib/...` path in a References list belongs to the version named on the line above it.
- `<page>.md:Lnn` is a line in the raw Markdown of `https://docs.typesafe.ai/<page>.md`, re-checked on 2026-09-29. Those pages change: many line numbers in the pre-split spec no longer matched, so an ADR cites a page by URL and section or field name wherever a line number did not re-verify.
- "Observed" marks a behavior seen by running it on Req 0.7.4, Finch 0.24.0, Mint 1.11.0, and Elixir 1.19.5 with OTP 28. The probe scripts are not committed.
- PR review findings are cited as `PR #<n> review <round>, finding <label>` with the comment URL. The label (`B` for blocking, `N` for non-blocking, `R` and `D` for later rounds) has no meaning outside that comment.
- Unbuilt material (logging, telemetry, and the live-API test plan) is not an ADR. It stays in the [last full spec](https://github.com/vinnie357/typesafe_sdk_ex/blob/e83f7a28c126f6f9ead2fb14bf8edcd3a9efd4c4/docs/spec.md), which no ADR endorses.

## Legacy references

Source and test comments written before the split cite `docs/spec.md` sections (`§5`, `§11 #52`, `q20`). [`docs/spec.md`](../spec.md) maps each to its ADR.

## Adding or amending an ADR

1. Copy the section layout of an existing ADR: Status, Date, Context, Decision, Consequences, Alternatives considered, References.
2. Write Decision lines as instructions in active voice, one per sentence, with no hedging verbs.
3. Date the decision, and date each amendment.
4. Name the JS source line for any behavior the decision copies or changes, and record each deviation in exactly one ADR.
5. Add the row to the index above and to the deviation index in ADR 0001.
