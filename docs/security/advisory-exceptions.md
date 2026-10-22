# Advisory exceptions

This file records every security advisory that this repo allow-lists, with a STRIDE review of each one.
Two CI gates read advisories: `mise run audit:hex` (`mix hex.audit`) and `mise run audit:deps`
(`mix deps.audit`). `test/test-audit-wiring.nu` checks this file against both allow-lists.
`mise run audit:advisory-doc` fails when a review in this file is overdue.

## Rule

- Allow-list an advisory only when no fixed release exists. Bump the dependency when a fix exists.
- Write the STRIDE section in this file before you allow-list the advisory.
- Put the advisory ID in both allow-lists: `.mix-audit-ignore` and `mix.exs` `hex: [ignore_advisories: [...]]`.
- Add both list entries and the section in the same commit. The pairing test fails otherwise.
- Use the GHSA ID when the advisory has one. Otherwise use the ID that `mix hex.audit` reports.
- Whoever adds the ID writes the section.
- The pull request review covers the section together with both list entries.
- Remove both list entries and the section together once a fix ships. The stale checks in both gates force this.
- The repo maintainer owns every exception.
- Review each exception every 90 days, or sooner when one of its review triggers fires.
- `audit:advisory-doc` fails CI once an exception's `Next review` date is before today. Review the exception to clear it.
- This file is one living document. Each review edits its section in place. Git history is the record of past reviews.

## Template

Copy this template once per exception, below the `## Exceptions` heading.

- The heading is `## <ID>`, spelled exactly as the allow-list entry.
- The anchor is the lower-cased ID, which GitHub derives from the heading. The allow-list comments link
  `docs/security/advisory-exceptions.md#<lower-cased ID>`.
- The `###` subsections appear in the order below. Keep all fourteen.
- Each STRIDE subsection (Spoofing through Elevation of privilege) states the threat as it applies to
  this repo, or says "Not applicable" with the reason.
- `### Review trigger` lists the triggers, then exactly one `Reviewed: YYYY-MM-DD` line and exactly one
  `Next review: YYYY-MM-DD` line. `Next review` is later than `Reviewed` and at most 90 days after it.
- A review overwrites `Reviewed` and `Next review`. Keep no review history, changelog or sign-off list here.
- `### Owner` is not empty.
- `### Tracking` holds the tracking issue URL, the same URL as in both allow-list comments.

```markdown
## <ID>

### Advisory

<package and locked version, severity, aliases, summary, advisory URL, and why no fixed release exists>

### Exposure

<how this repo reaches the vulnerable code: dependency path, MIX_ENV scope, whether the release ships it>

### Spoofing

<threat as it applies to this repo, or "Not applicable" with the reason>

### Tampering

<threat as it applies to this repo, or "Not applicable" with the reason>

### Repudiation

<threat as it applies to this repo, or "Not applicable" with the reason>

### Information disclosure

<threat as it applies to this repo, or "Not applicable" with the reason>

### Denial of service

<threat as it applies to this repo, or "Not applicable" with the reason>

### Elevation of privilege

<threat as it applies to this repo, or "Not applicable" with the reason>

### Likelihood and impact

<likelihood and impact in prod, in dev, and in CI>

### Existing mitigations

<controls that already limit the risk>

### Residual risk

<the risk that remains after the mitigations>

### Review trigger

- a fixed release of the package
- the advisory is revised
- the vulnerable code becomes reachable from a new path
- the locked version changes
- the next review date

Reviewed: YYYY-MM-DD
Next review: YYYY-MM-DD

### Owner

<the repo maintainer>

### Tracking

https://github.com/vinnie357/typesafe_sdk_ex/issues/<N>
```

## Exceptions

No exceptions.
