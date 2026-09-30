# ADR 0011: Question builders and pre-send request validation

**Status:** Accepted
**Date:** 2026-09-17

## Context

The JS SDK builds questions with `noul`, `choice`, and `score` (`src/questions.ts:22-63`), throws `TypeSafeError` on a wrong criteria container, and validates the question set before it sends anything (`questions.ts:70-89`). It forwards the caller's request object structurally, so a missing `state` becomes `undefined`, which `JSON.stringify` drops from the body (`src/client.ts:311-325`).

The docs and the JS types disagree on required fields and bounds (ADR 0001).

## Decision

### Builders

1. Builders return plain atom-keyed maps that encode as the wire objects (`questions.ts:22-63`):

   | Call | Result |
   |---|---|
   | `noul()` | `%{type: "noul", instructions: nil}` |
   | `noul(i)` | `%{type: "noul", instructions: i}`, with no `criteria` key |
   | `noul(i, c)` | `%{type: "noul", instructions: i, criteria: c}`. `c` is a map or `nil`, and `nil` encodes as `null`. |
   | `choice(i, criteria_map)` | `%{type: "choice", instructions: i, criteria: criteria_map}` |
   | `score(i, criteria_list)` | `%{type: "score", instructions: i, criteria: criteria_list}` |

2. `choice/2` requires a map and `score/2` requires a list. Guard clauses enforce it, and a wrong container raises `FunctionClauseError`. This is a programmer error, and it deviates from JS, which throws `TypeSafeError` with a message (`questions.ts:41-45,59-61`).
3. The builders pass criteria through without rewriting them.
4. Instructions and descriptions accept any JSON term, including `nil`. The SDK does not validate `instructions` (ADR 0001).
5. `system_one/3` accepts raw question maps as well as builder output.

### Request shape

6. The `system_one/3` request is an atom-keyed map: `%{state: term, questions: %{id => question}, ...extra}`.
7. `state: nil` is valid and encodes as `null`.
8. A request without `:state`, or with string keys, returns `{:error, %TypeSafe.Error{}}` with zero HTTP calls. The SDK does not normalize it. This deviates from JS, which drops `state: undefined`.
9. The error message names the actual problem. It says `:questions` must be an atom-keyed map when `:state` is present, and it says the `:state` key is missing otherwise.
10. A request that is not a map raises `FunctionClauseError`.
11. A `nil` `:model` counts as absent, and the client's `default_model` fills it (JS `??`, `client.ts:318`). A non-`nil` `:model` wins.
12. The SDK forwards every extra top-level key, including keys with `nil` values.

### Pre-send validation

13. Validation runs after the call options and before the request. Each failure returns `{:error, %TypeSafe.Error{}}` and makes zero HTTP calls (`questions.ts:70-89`, `test/client.test.ts:377-395`):
    - an empty `questions` map: `"At least one question is required."`
    - a `score` question whose `criteria` is missing or not a list: `Score question "q" has criteria that are not a list; score criteria must be a list of descriptions indexed by score from zero.`
    - a `score` question with fewer than two criteria: `Score question "q" has <n> criteria; at least two scores are required.`
14. Validation reads `type` and `criteria` under atom or string keys. It returns the questions unchanged.
15. The SDK sets no upper bound on score levels or choice options. The server's 422 enforces them (ADR 0001).

## Consequences

### Positive

- An invalid question set never reaches the network, so it never bills.
- Callers who decode JSON questions from config work with string keys inside the atom-keyed map.

### Negative

- A missing `:state` is an error, where JS sends the request without it. A caller who wants no state passes `state: nil`, which sends `null`. The wire body then differs from JS.
- The `FunctionClauseError` from a builder carries no custom message.
- A `nil` request raises, and an all-string-keyed request map is rejected rather than accepted.
- The live API's answer to an omitted `instructions`, `state: nil`, and a score with eleven levels is unverified. The SDK sends them.
- A non-map question value (for example `q: "hello"`) is sent, like JS, where `question.type` is `undefined` and the check skips it (PR #1 review round 2).

## Alternatives considered

- **Normalize string-keyed requests.** Rejected by operator decision: the signature is `%{state:, questions:} = request` (PR #1 review round 1, N5, resolved by the operator).
- **Raise `FunctionClauseError` for a missing `:state`.** Rejected: a caller error returns `{:error, _}` so callers do not rescue.
- **Validate `instructions` as required per the docs.** Rejected: JS follows the types, and the SDK follows JS (ADR 0001).
- **A custom error for wrong builder containers.** Not chosen: guards match the JS runtime throw, and Elixir callers see the failing clause in the stacktrace.

## References

- JS: `src/questions.ts:22-63,70-89`, `src/client.ts:311-325`, `src/types.ts:155-172` (the request payload), `test/client.test.ts:236,279` (`noul` without criteria), `test/client.test.ts:262-322,324-395`.
- PR #1 review round 1, findings B3, B4, N5: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5714770534
- PR #1 review round 2, finding R5 and the note on question keys: https://github.com/vinnie357/typesafe_sdk_ex/pull/1#issuecomment-5715301129
