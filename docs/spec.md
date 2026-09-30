# TypeSafe SDK port spec (superseded)

Split into ADRs on 2026-09-29. Decisions live in [`docs/adr/`](adr/README.md). This file only resolves legacy references (`§5`, `q20`, `§11 S3b #18`) in source and test comments. It carries no decision text. Test comments that cite spec line numbers (for example `spec §3 L55`) refer to earlier spec revisions: read those at commit `a935ea1` (`git show a935ea1:docs/spec.md`).

Last full spec, for material that has no ADR (logging, the slice plan and acceptance criteria, the ordered test list, the live-API test plan): https://github.com/vinnie357/typesafe_sdk_ex/blob/e83f7a28c126f6f9ead2fb14bf8edcd3a9efd4c4/docs/spec.md

| Legacy token | Where it went |
|---|---|
| §1, §9 (not-ported table) | [ADR 0001](adr/0001-port-js-sdk-as-reference.md) |
| §2 | [ADR 0003](adr/0003-public-api-facade-and-tagged-tuples.md); `RetryPolicy` row: [ADR 0007](adr/0007-retry-policy-and-engine-on-req-retry.md) |
| §3 headers, body parsing, `decode_body` | [ADR 0005](adr/0005-sdk-owned-request-settings-headers-and-body-decoding.md) |
| §3 env vars, §4 `api_key`, `base_url`, `default_model`, `log_level`, `get_env` | [ADR 0004](adr/0004-configuration-resolution-and-option-validation.md) |
| §4 `req_options` (R2, A′), header values (R3) | [ADR 0005](adr/0005-sdk-owned-request-settings-headers-and-body-decoding.md) |
| §4 `retry` row, `inspect` of a policy | [ADR 0007](adr/0007-retry-policy-and-engine-on-req-retry.md) |
| §4 `timeout` row | [ADR 0010](adr/0010-per-attempt-timeout-on-req-receive-timeout.md) |
| §5 policy, decision, delay, ceiling, Req `:retry` analysis | [ADR 0007](adr/0007-retry-policy-and-engine-on-req-retry.md) |
| §5 `api_timeout_error`, POST retries, connect timeouts | [ADR 0008](adr/0008-timeouts-are-not-retried-by-default.md) |
| §5 Retry-After parsing | [ADR 0009](adr/0009-retry-after-parsing.md) |
| §5 Timeout | [ADR 0010](adr/0010-per-attempt-timeout-on-req-receive-timeout.md) |
| §5 test seam, §11 conventions | [ADR 0012](adr/0012-test-seams-without-mocking-libraries.md) |
| §6 | [ADR 0006](adr/0006-error-taxonomy.md) |
| §7 | [ADR 0013](adr/0013-telemetry-events-and-default-logger.md) |
| §8 builders, request shape, validation | [ADR 0011](adr/0011-question-builders-and-pre-send-validation.md); "Answers": [ADR 0003](adr/0003-public-api-facade-and-tagged-tuples.md) |
| §9a | [ADR 0002](adr/0002-runtime-dependency-is-req-only.md); stub rows: [ADR 0012](adr/0012-test-seams-without-mocking-libraries.md) |
| §10 slices S1 to S4 | Last full spec. The v0.2.0 release gate is [issue #8](https://github.com/vinnie357/typesafe_sdk_ex/issues/8) |
| §10 slice S5 (logging) | [ADR 0013](adr/0013-telemetry-events-and-default-logger.md) |
| §11 `S<n> #<m>` test rows | Last full spec. Each test cites its JS line in a comment |
| §12 q1 to q8 | [ADR 0001](adr/0001-port-js-sdk-as-reference.md) (rulings table) |
| §12 q9 | [ADR 0010](adr/0010-per-attempt-timeout-on-req-receive-timeout.md) (budget), [ADR 0007](adr/0007-retry-policy-and-engine-on-req-retry.md) (`exceptions`, `predicate`) |
| §12 q10, q12 | [ADR 0003](adr/0003-public-api-facade-and-tagged-tuples.md), [ADR 0011](adr/0011-question-builders-and-pre-send-validation.md) |
| §12 q11 | Log level spelling: [ADR 0004](adr/0004-configuration-resolution-and-option-validation.md). Redaction: [ADR 0013](adr/0013-telemetry-events-and-default-logger.md) |
| §12 q13 | [ADR 0010](adr/0010-per-attempt-timeout-on-req-receive-timeout.md) |
| §12 q14 | [ADR 0005](adr/0005-sdk-owned-request-settings-headers-and-body-decoding.md) |
| §12 q15, q21 | [ADR 0009](adr/0009-retry-after-parsing.md) |
| §12 q16 | [ADR 0004](adr/0004-configuration-resolution-and-option-validation.md) |
| §12 q17 | [ADR 0006](adr/0006-error-taxonomy.md) |
| §12 q18 | [ADR 0002](adr/0002-runtime-dependency-is-req-only.md) |
| §12 q20 | [ADR 0008](adr/0008-timeouts-are-not-retried-by-default.md) |
| §12 q19 (request tags) | [ADR 0013](adr/0013-telemetry-events-and-default-logger.md) |
| §13 | Not built. Last full spec |
| Review labels (`B`, `N`, `R`, `D`, "Gate 4") | The PR comment URL next to the decision in the ADR's References |
