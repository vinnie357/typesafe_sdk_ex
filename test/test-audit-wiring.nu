#!/usr/bin/env nu
# test-audit-wiring.nu — T2-T7: audit gate wiring, allow-list parity, the STRIDE doc, the CI workflow and dependabot.
#
# Reads files only; evaluates nothing. Each section runs even when an earlier
# one fails, so one run reports every red section. Exits 1 on any failure.
#
# T2 wiring:
#   - mise.toml [tasks."audit:deps"] runs `nu scripts/deps-audit.nu` and has
#     `depends = ["audit:hex"]`.
#   - [tasks."audit:hex"] runs `nu scripts/hex-audit.nu` and has
#     `depends = ["deps"]`.
#   - tasks.ci.depends contains deps, audit:hex, audit:deps, audit:advisory-doc,
#     audit:otp and test:audit (membership only: mise runs depends in parallel, so order
#     means nothing). It does not contain compile, test or credo: `mix ci` in
#     tasks.ci.run sequences them after every depends task, so deps.audit never
#     races a compile on _build.
#   - tasks.ci.run runs `mix ci` and never names the removed hex-audit task.
#   - [tasks."test:audit"] depends on exactly the six test tasks
#     test:hex-audit, test:hex-audit-offline, test:deps-audit,
#     test:audit-wiring, test:advisory-doc and test:otp-audit. Each test task,
#     audit:advisory-doc and audit:otp runs its file.
#   - No [tasks."hex-audit"] remains; audit:hex supersedes it.
#   - mise.toml [tools] pins "github:nushell/nushell" to an exact X.Y.Z.
#   - mise.toml [tools] pins erlang = "28.5.0.8" and elixir = "1.19.6-otp-28"
#     (exact strings), and the elixir `-otp-N` suffix equals the erlang major.
#   - mix.exs declares :mix_audit with `only: [:dev, :test]` and `runtime: false`.
#   - .mix-audit-ignore exists at the repo root; .mix-audit-skips does not
#     (guards the earlier name, so every repo uses one file name).
#   - The positive-control lock's "bandit" entry has the real lock's 8-element
#     shape (checked against the real jason entry; this repo locks no bandit). A lock mix_audit cannot evaluate reads as 0 deps and passes, so a
#     control held to the real shape proves mix_audit parses that shape.
# T3 allow-list parity:
#   - IDs in mix.exs `hex: [ignore_advisories: ...]` equal the ID lines of
#     .mix-audit-ignore.
#   - Each ID sits directly under `# <ID> https://github.com/vinnie357/typesafe_sdk_ex/issues/<N> docs/security/advisory-exceptions.md#<lower ID>`
#     in both files, with the same <N>.
#   - .mix-audit-ignore lines carry no leading or trailing whitespace
#     (mix_audit does not trim, so a stray space turns a comment into an ID or
#     makes an ID unmatchable).
#   - A known CVE with a GHSA alias appears only in its GHSA form.
# T4 doc parity (docs/security/advisory-exceptions.md):
#   - every allow-list ID has a `## <ID>` section with the 14 `###`
#     subsections in order;
#   - `### Tracking` names the same issue number as the T3 comments;
#   - `### Owner` is non-empty;
#   - `### Review trigger` has exactly one `Reviewed: YYYY-MM-DD` and one
#     `Next review: YYYY-MM-DD` line; both are valid dates, Next review is
#     later than Reviewed, and Next review is at most 90 days after Reviewed
#     (clock-free; fixtures pin 90 days as the limit and 91 days as a failure).
#   The overdue check against today lives in
#   scripts/advisory-doc.nu, task audit:advisory-doc; see test/test-advisory-doc.nu.
#   The doc is one living record: a review overwrites Reviewed, Next review and
#   the analysis in place, and git history keeps past reviews. Nothing here
#   requires keeping old reviews.
# T5 no orphans: every `## <ID>` section in the doc is on both allow-lists.
# T6 CI workflow (.github/workflows/ci.yml, read as text and as YAML):
#   - every `uses:` is `<owner>/<repo>@<40 hex> # v<X.Y.Z>`;
#   - no workflow-, job- or step-level `env` sets GITHUB_TOKEN (mise-action
#     installs tools with its own token; a job token reaches every later step);
#   - exactly one matrix leg has `pinned: true`, every leg sets `pinned` to a
#     boolean, and the pinned leg's elixir and otp equal mise.toml [tools]
#     elixir and erlang (so `mise run` on that leg resolves the same pair);
#   - exactly one leg has `pinned: false`; its pair is elixir "1.18.5-otp-27"
#     and otp "27.3.4.19" (exact strings, the latest OTP 27 patch with the
#     27-line CVE fixes), and its elixir `-otp-N` suffix equals its otp major;
#   - a step with `if: matrix.pinned` runs `mise run ci`;
#   - steps with `if: !matrix.pinned` run `mise exec -- mix deps.get
#     --check-locked` and `mise exec -- mix ci` (`mise run` ignores
#     MISE_*_VERSION, so the compat leg calls mix through `mise exec`);
#   - every step that can run on the compat leg (no `if`, or any `if` other
#     than `matrix.pinned`) runs no `nu scripts/`, `nu test/`, `mise run`,
#     hex.audit, deps.audit or gitleaks; in particular it never runs
#     audit:otp (OTP 27 is below the 28.x floor by design);
#   - no step runs a bare `mix hex.audit`.
# T7 dependabot (.github/dependabot.yml, read as YAML):
#   - version is 2;
#   - updates has exactly one "mix" entry and one "github-actions" entry;
#   - each of them has directory "/" and schedule.interval "weekly".
#
# Doc sections: only `## ` headings outside fenced code blocks whose text
# matches the advisory ID shape `^[A-Z][A-Z0-9]*(-[A-Za-z0-9]+)+$` start a
# section, so policy headings (`## Rule`, `## Template`, `## Exceptions`) and a
# fenced template `## <ID>` are not sections. Fenced lines inside an ID section
# are dropped. The clock-free, file-free "T5 fixture: doc-sections" entry pins
# this on fixture text.

use std/assert

const root = path self ..

const subsections = [
  "Advisory"
  "Exposure"
  "Spoofing"
  "Tampering"
  "Repudiation"
  "Information disclosure"
  "Denial of service"
  "Elevation of privilege"
  "Likelihood and impact"
  "Existing mitigations"
  "Residual risk"
  "Review trigger"
  "Owner"
  "Tracking"
]

# Known CVE -> GHSA alias pairs; the CVE form must not appear on either list.
const aliases = [
  {cve: "CVE-2026-43966", ghsa: "GHSA-w4f7-4cxr-rv3c"}
]

const doc_path = "docs/security/advisory-exceptions.md"

const max_review_gap_days = 90

# Parsed YYYY-MM-DD, or null when it is not a valid date.
def parse-day [text: string] {
  if not ($text =~ '^\d{4}-\d{2}-\d{2}$') { return null }
  try { $text | into datetime --format "%Y-%m-%d" } catch { null }
}

# true when Next review is after Reviewed and at most 90 days after it.
def review-gap-ok [reviewed: string, next_review: string] {
  let r = (parse-day $reviewed)
  let n = (parse-day $next_review)
  if ($r == null) or ($n == null) { return false }
  # Rounded: local dates across a DST change differ by a fractional day.
  let days = (($n - $r) / 1day | math round)
  ($days > 0) and ($days <= $max_review_gap_days)
}

def review-gap-fixtures [] {
  assert equal (review-gap-ok "2026-10-19" "2027-01-17") true "90 days after Reviewed is the limit and must pass"
  assert equal (review-gap-ok "2026-10-19" "2027-01-18") false "91 days after Reviewed must fail"
  assert equal (review-gap-ok "2026-10-19" "2026-10-19") false "Next review equal to Reviewed must fail"
  assert equal (review-gap-ok "2026-10-19" "2026-10-18") false "Next review before Reviewed must fail"
  assert equal (review-gap-ok "2026-10-19" "2027-02-30") false "an invalid date must fail"
}

def read [rel: string] {
  open --raw ($root | path join $rel)
}

def comment-pattern [id: string] {
  let anchor = ($id | str lowercase)
  $"^# ($id) https://github\\.com/vinnie357/typesafe_sdk_ex/issues/\(?<n>\\d+\) docs/security/advisory-exceptions\\.md#($anchor)$"
}

# {id, comment} for each quoted ID in mix.exs hex ignore_advisories.
def mix-exs-entries [] {
  let blocks = (read "mix.exs" | parse --regex '(?s)ignore_advisories:\s*\[(?<body>[^\]]*)\]')
  assert equal ($blocks | length) 1 "mix.exs must have one hex ignore_advisories list"
  let lines = ($blocks.0.body | lines | each {|l| $l | str trim } | where {|l| $l != "" })
  $lines | enumerate | where {|e| $e.item | str starts-with '"' } | each {|e|
    {
      id: ($e.item | parse --regex '^"(?<id>[^"]+)"').0.id
      comment: (if $e.index > 0 { $lines | get ($e.index - 1) } else { "" })
    }
  }
}

# {id, comment} for each ID line in .mix-audit-ignore; [] when the file is
# missing (T2 asserts it exists), so T3-T5 still report their own failures.
def ignore-file-entries [] {
  let file = ($root | path join ".mix-audit-ignore")
  if not ($file | path exists) { return [] }
  let lines = (open --raw $file | lines)
  $lines | enumerate | where {|e| not (($e.item | str starts-with "#") or ($e.item | str trim | is-empty)) } | each {|e|
    {id: $e.item, comment: (if $e.index > 0 { $lines | get ($e.index - 1) } else { "" })}
  }
}

def issue-number [entry: record] {
  let hit = ($entry.comment | parse --regex (comment-pattern $entry.id))
  assert equal ($hit | length) 1 $"comment above ($entry.id) must be `# ($entry.id) https://github.com/vinnie357/typesafe_sdk_ex/issues/<N> ($doc_path)#($entry.id | str lowercase)`, got: ($entry.comment)"
  $hit.0.n
}

const id_heading_re = '^[A-Z][A-Z0-9]*(-[A-Za-z0-9]+)+$'

# `## <ID>` sections of text, outside fenced code blocks and keyed by an
# ID-shaped heading: {id, subsections: list<{name, body}>}. Fenced lines inside
# an ID section are dropped.
def doc-sections-of [text: string] {
  mut sections = []
  mut current = {id: "", body: []}
  mut fenced = false
  for l in ($text | lines) {
    if ($l | str starts-with "```") { $fenced = not $fenced }
    if (not $fenced) and ($l | str starts-with "## ") {
      if $current.id != "" { $sections = ($sections | append $current) }
      let heading = ($l | str substring 3.. | str trim)
      $current = {id: (if ($heading =~ $id_heading_re) { $heading } else { "" }), body: []}
    } else if (not $fenced) and $current.id != "" {
      $current.body = ($current.body | append $l)
    }
  }
  if $current.id != "" { $sections = ($sections | append $current) }
  $sections | each {|sec|
    let chunk = ($sec.body | str join "\n")
    let subs = ($chunk | split row --regex '(?m)^### ' | skip 1 | each {|s|
      {name: ($s | lines | first | str trim), body: ($s | lines | skip 1 | str join "\n")}
    })
    {id: $sec.id, subsections: $subs}
  }
}

def doc-sections [] {
  doc-sections-of (read $doc_path)
}

# Clock-free and file-free: policy headings and fenced template headings are
# not sections; a real ID heading is.
def doc-sections-fixture [] {
  let fence = "```"
  let policy = ([
    "# Advisory exceptions"
    ""
    "## Rule"
    ""
    "Every allow-listed ID gets a section."
    ""
    "## Template"
    ""
    $"($fence)markdown"
    "## <ID>"
    ""
    "## GHSA-xxxx-xxxx-xxxx"
    ""
    "### Advisory"
    ""
    "Next review: 2000-01-01"
    $fence
    ""
    "## Exceptions"
    ""
    "No exceptions."
  ] | str join "\n")
  assert equal (doc-sections-of $policy | length) 0 $"policy headings and a fenced template must yield 0 sections, got: (doc-sections-of $policy | to nuon)"

  let real = ([
    $policy
    ""
    "## GHSA-aaaa-bbbb-cccc"
    ""
    "### Advisory"
    ""
    "Real advisory text."
    ""
    $"($fence)markdown"
    "### Fenced"
    $fence
    ""
    "### Owner"
    ""
    "Maintainer"
  ] | str join "\n")
  let got = (doc-sections-of $real)
  assert equal ($got | length) 1 $"a real ID heading must yield 1 section, got: ($got | to nuon)"
  assert equal $got.0.id "GHSA-aaaa-bbbb-cccc" "the section id must be the heading text"
  assert equal ($got.0.subsections | get name) ["Advisory" "Owner"] "subsections must be in order, with fenced headings dropped"
  assert (($got.0.subsections | where name == "Owner" | get 0.body) | str contains "Maintainer") "a subsection body must hold its lines"
}

# N from an elixir `X.Y.Z-otp-N` version; null when the suffix is missing.
def otp-suffix [elixir] {
  if ($elixir | describe) != "string" { return null }
  let hit = ($elixir | parse --regex '-otp-(?<n>\d+)$')
  if ($hit | is-empty) { null } else { $hit.0.n | into int }
}

# Major of an OTP version string such as 28.5.0.8; null when not numeric.
def otp-major [otp] {
  if ($otp | describe) != "string" { return null }
  let hit = ($otp | parse --regex '^(?<n>\d+)(\.\d+)*$')
  if ($hit | is-empty) { null } else { $hit.0.n | into int }
}

def t2-wiring [] {
  let tasks = (open ($root | path join "mise.toml") | get tasks)
  let deps_task = ($tasks | get -o "audit:deps")
  assert ($deps_task != null) "mise.toml must define [tasks.\"audit:deps\"]"
  assert equal $deps_task.run "nu scripts/deps-audit.nu" "audit:deps must run nu scripts/deps-audit.nu"
  assert equal ($deps_task | get -o depends) ["audit:hex"] "audit:deps must declare depends = [\"audit:hex\"]"

  # audit:hex needs fetched deps on a cold checkout.
  let hex_task = ($tasks | get -o "audit:hex")
  assert ($hex_task != null) "mise.toml must define [tasks.\"audit:hex\"]"
  assert equal ($hex_task | get -o run) "nu scripts/hex-audit.nu" "audit:hex must run nu scripts/hex-audit.nu"
  assert equal ($hex_task | get -o depends) ["deps"] "audit:hex must declare depends = [\"deps\"]"

  assert (($tasks | get -o "hex-audit") == null) "mise.toml must not define [tasks.\"hex-audit\"]; audit:hex supersedes it"

  let ci = ($tasks.ci | get -o depends | default [])
  for t in ["deps" "audit:hex" "audit:deps" "audit:advisory-doc" "audit:otp" "test:audit"] {
    assert ($t in $ci) $"tasks.ci.depends must include ($t); got: ($ci)"
  }
  # deps.audit compiles deps; a parallel compile would race it on _build. So
  # compile, test and credo run inside `mix ci`, in ci.run, after every depends task.
  for t in ["compile" "test" "credo"] {
    assert (not ($t in $ci)) $"tasks.ci.depends must not include ($t) \(it races mix deps.audit on _build\); got: ($ci)"
  }
  let ci_run = ($tasks.ci | get -o run | default [] | append [] | flatten)
  assert ("mix ci" in $ci_run) $"tasks.ci.run must include `mix ci`; got: ($ci_run)"
  assert (not ($ci_run | any {|c| $c | str contains "hex-audit" })) $"tasks.ci.run must not run the removed hex-audit task; got: ($ci_run)"

  let test_tasks = ["test:hex-audit" "test:hex-audit-offline" "test:deps-audit" "test:audit-wiring" "test:advisory-doc" "test:otp-audit"]
  let test_audit = ($tasks | get -o "test:audit")
  assert ($test_audit != null) "mise.toml must define [tasks.\"test:audit\"]"
  assert equal ($test_audit | get -o depends | default [] | sort) ($test_tasks | sort) "test:audit must depend on exactly the six audit test tasks"

  for pair in [["test:hex-audit" "nu test/test-hex-audit.nu"] ["test:deps-audit" "nu test/test-deps-audit.nu"] ["test:hex-audit-offline" "nu test/test-hex-audit-offline.nu"] ["test:audit-wiring" "nu test/test-audit-wiring.nu"] ["test:advisory-doc" "nu test/test-advisory-doc.nu"] ["audit:advisory-doc" "nu scripts/advisory-doc.nu"] ["audit:otp" "nu scripts/otp-audit.nu"] ["test:otp-audit" "nu test/test-otp-audit.nu"]] {
    assert equal ($tasks | get -o $pair.0 | get -o run) $pair.1 $"($pair.0) must run `($pair.1)`"
  }

  let nu_pin = (open ($root | path join "mise.toml") | get -o tools | default {} | get -o "github:nushell/nushell")
  assert ($nu_pin != null) "mise.toml [tools] must pin \"github:nushell/nushell\""
  assert (($nu_pin | describe) == "string" and ($nu_pin =~ '^\d+\.\d+\.\d+$')) $"mise.toml must pin nushell to an exact X.Y.Z version; got: ($nu_pin)"

  let tools = (open ($root | path join "mise.toml") | get -o tools | default {})
  assert equal ($tools | get -o erlang) "28.5.0.8" "mise.toml [tools] must pin erlang = \"28.5.0.8\" (the OTP CVE floor)"
  assert equal ($tools | get -o elixir) "1.19.6-otp-28" "mise.toml [tools] must pin elixir = \"1.19.6-otp-28\""
  assert equal (otp-suffix ($tools | get -o elixir)) (otp-major ($tools | get -o erlang)) $"the mise.toml elixir pin's -otp-N suffix must equal the erlang pin's major; got elixir ($tools | get -o elixir), erlang ($tools | get -o erlang)"

  let mix_audit = (read "mix.exs" | lines | where {|l| $l =~ '\{:mix_audit,' })
  assert equal ($mix_audit | length) 1 "mix.exs must declare :mix_audit once"
  assert ($mix_audit.0 | str contains "only: [:dev, :test]") "mix_audit must be only: [:dev, :test]"
  assert ($mix_audit.0 | str contains "runtime: false") "mix_audit must be runtime: false"

  assert (($root | path join ".mix-audit-ignore") | path exists) ".mix-audit-ignore must exist at the repo root"
  assert (not (($root | path join ".mix-audit-skips") | path exists)) ".mix-audit-skips must not exist; the one cross-repo name is .mix-audit-ignore"

  # this repo locks no bandit; jason (runtime dep) carries the real lock's shape.
  let shape_of = {|pkg| $'^  "($pkg)": \{:hex, :($pkg), "[^"]+", "[0-9a-f]{64}", \[:mix\], \[.*\], "hexpm", "[0-9a-f]{64}"\},$' }
  let real = (read "mix.lock" | lines | where {|l| $l | str starts-with '  "jason":' })
  let control = (read "test/fixtures/deps_audit/positive_control/mix.lock" | lines | where {|l| $l | str starts-with '  "bandit":' })
  assert equal ($real | length) 1 "mix.lock must have one jason entry"
  assert equal ($control | length) 1 "the positive-control lock must have one bandit entry"
  assert ($real.0 =~ (do $shape_of "jason")) "the real mix.lock jason entry must have the 8-element hex shape (update this test if mix changes the lock format)"
  assert ($control.0 =~ (do $shape_of "bandit")) "the positive-control bandit entry must have the real lock's 8-element shape"
  assert ($control.0 | str contains ':bandit, "1.5.0",') "the positive control must lock bandit 1.5.0"
}

def t3-parity [] {
  let hex = (mix-exs-entries)
  let ignore = (ignore-file-entries)
  assert equal ($hex | get id | sort) ($ignore | get id | sort) "mix.exs ignore_advisories and .mix-audit-ignore must list the same IDs"

  assert (($root | path join ".mix-audit-ignore") | path exists) ".mix-audit-ignore must exist at the repo root"
  for line in (read ".mix-audit-ignore" | lines) {
    assert equal $line ($line | str trim) $".mix-audit-ignore lines must have no leading or trailing whitespace: '($line)'"
  }

  for e in $ignore {
    let hex_entry = ($hex | where id == $e.id)
    assert equal ($hex_entry | length) 1 $"($e.id) must appear once in mix.exs"
    assert equal (issue-number $e) (issue-number $hex_entry.0) $"($e.id) must name the same issue in both files"
  }
  for e in $hex { issue-number $e | ignore }

  for a in $aliases {
    assert (not ($a.cve in ($hex | get id))) $"mix.exs must use ($a.ghsa), not its alias ($a.cve)"
    assert (not ($a.cve in ($ignore | get id))) $".mix-audit-ignore must use ($a.ghsa), not its alias ($a.cve)"
  }
}

def t4-doc [] {
  review-gap-fixtures
  let sections = (doc-sections)
  let ignore = (ignore-file-entries)
  for id in ((mix-exs-entries | get id) | append ($ignore | get id) | uniq) {
    let matches = ($sections | where id == $id)
    assert equal ($matches | length) 1 $"($doc_path) must have one `## ($id)` section"
    let s = $matches.0
    assert equal ($s.subsections | get name) $subsections $"`## ($id)` must have the 14 ### subsections in order"

    let sub = {|name| $s.subsections | where name == $name | get 0.body }

    let entry = ($ignore | where id == $id)
    if ($entry | is-not-empty) {
      let n = (issue-number $entry.0)
      assert ((do $sub "Tracking") =~ $'issues/($n)\b') $"`## ($id)` ### Tracking must name issue ($n)"
    }

    assert ((do $sub "Owner") | str trim | is-not-empty) $"`## ($id)` ### Owner must not be empty"

    let trigger = (do $sub "Review trigger" | lines)
    let reviewed = ($trigger | parse --regex '^Reviewed: (?<d>\d{4}-\d{2}-\d{2})$')
    let next = ($trigger | parse --regex '^Next review: (?<d>\d{4}-\d{2}-\d{2})$')
    assert equal ($reviewed | length) 1 $"`## ($id)` ### Review trigger must have exactly one `Reviewed: YYYY-MM-DD` line"
    assert equal ($next | length) 1 $"`## ($id)` ### Review trigger must have exactly one `Next review: YYYY-MM-DD` line"
    assert ((parse-day $reviewed.0.d) != null) $"`## ($id)` Reviewed date is not a valid date: ($reviewed.0.d)"
    assert ((parse-day $next.0.d) != null) $"`## ($id)` Next review date is not a valid date: ($next.0.d)"
    assert (review-gap-ok $reviewed.0.d $next.0.d) $"`## ($id)` Next review \(($next.0.d)\) must be 1 to ($max_review_gap_days) days after Reviewed \(($reviewed.0.d)\)"
  }
}

def t5-orphans [] {
  let hex = (mix-exs-entries | get id)
  let ignore = (ignore-file-entries | get id)
  for s in (doc-sections) {
    assert ($s.id in $hex) $"doc section `## ($s.id)` must be on mix.exs ignore_advisories"
    assert ($s.id in $ignore) $"doc section `## ($s.id)` must be on .mix-audit-ignore"
  }
}

const ci_path = ".github/workflows/ci.yml"

# A step's `if:` with `${{ }}` and all whitespace removed; "" when absent.
def step-if [step: record] {
  $step | get -o if | default "" | into string | str replace --all --regex '\$\{\{|\}\}|\s' ""
}

def step-run [step: record] {
  $step | get -o run | default "" | into string
}

def t6-ci [] {
  let text = (read $ci_path)
  let wf = ($text | from yaml)

  let uses = ($text | lines | where {|l| $l =~ '^\s*(-\s+)?uses:' })
  assert (($uses | length) > 0) $"($ci_path) must have `uses:` lines"
  for l in $uses {
    assert ($l =~ '^\s*(-\s+)?uses:\s+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+\s*$') $"every `uses:` must be `<owner>/<repo>@<40 hex> # v<X.Y.Z>`; got: ($l | str trim)"
  }

  assert (not ($wf | get -o env | default {} | columns | any {|k| $k == "GITHUB_TOKEN" })) $"($ci_path) workflow env must not set GITHUB_TOKEN"

  let tools = (open ($root | path join "mise.toml") | get tools)
  let jobs = ($wf | get jobs | transpose name job)
  for j in $jobs {
    assert (not ($j.job | get -o env | default {} | columns | any {|k| $k == "GITHUB_TOKEN" })) $"job ($j.name) env must not set GITHUB_TOKEN"
    for s in ($j.job | get -o steps | default []) {
      assert (not ($s | get -o env | default {} | columns | any {|k| $k == "GITHUB_TOKEN" })) $"step `($s | get -o name | default '?')` in job ($j.name) must not set GITHUB_TOKEN in env"
    }
  }

  let ci_job = ($wf | get jobs | get -o ci)
  assert ($ci_job != null) $"($ci_path) must define jobs.ci"
  let legs = ($ci_job | get -o strategy.matrix.include | default [])
  assert (($legs | length) > 0) "jobs.ci must have a matrix include list"
  for leg in $legs {
    assert (($leg | get -o pinned | describe) == "bool") $"every matrix leg must set `pinned` to a boolean; got: ($leg | to nuon)"
  }
  let pinned = ($legs | where {|leg| ($leg | get -o pinned) == true })
  assert equal ($pinned | length) 1 $"exactly one matrix leg must have pinned: true; got: ($legs | to nuon)"
  assert equal ($pinned.0 | get -o elixir) $tools.elixir "the pinned leg's elixir must equal mise.toml [tools] elixir"
  assert equal ($pinned.0 | get -o otp) $tools.erlang "the pinned leg's otp must equal mise.toml [tools] erlang"

  let compat = ($legs | where {|leg| ($leg | get -o pinned) == false })
  assert equal ($compat | length) 1 $"exactly one matrix leg must have pinned: false; got: ($legs | to nuon)"
  assert equal ($compat.0 | get -o elixir) "1.18.5-otp-27" "the compat leg's elixir must be \"1.18.5-otp-27\""
  assert equal ($compat.0 | get -o otp) "27.3.4.19" "the compat leg's otp must be \"27.3.4.19\", the latest OTP 27 patch with the 27-line CVE fixes"
  assert equal (otp-suffix ($compat.0 | get -o elixir)) (otp-major ($compat.0 | get -o otp)) $"the compat leg's elixir -otp-N suffix must equal its otp major; got: ($compat.0 | to nuon)"

  let steps = ($ci_job | get -o steps | default [])
  let on_pinned = ($steps | where {|s| (step-if $s) == "matrix.pinned" })
  let only_compat = ($steps | where {|s| (step-if $s) == "!matrix.pinned" })
  let maybe_compat = ($steps | where {|s| (step-if $s) != "matrix.pinned" })

  assert ($on_pinned | any {|s| (step-run $s | str trim) == "mise run ci" }) "a step with `if: matrix.pinned` must run `mise run ci`"
  for cmd in ["mise exec -- mix deps.get --check-locked" "mise exec -- mix ci"] {
    assert ($only_compat | any {|s| (step-run $s | lines | each {|l| $l | str trim }) | any {|l| $l == $cmd } }) $"a step with `if: !matrix.pinned` must run `($cmd)`"
  }

  for s in $maybe_compat {
    let run = (step-run $s)
    for banned in ["nu scripts/otp-audit.nu" "mise run ci"] {
      assert (not ($run | str contains $banned)) $"step `($s | get -o name | default '?')` can run on the compat leg; a compat-capable step must not run `nu scripts/otp-audit.nu` or `mise run ci` \(OTP 27 is below the 28.x floor by design\); its if: '($s | get -o if | default '')'"
    }
    for banned in ["nu scripts/" "nu test/" "mise run" "hex.audit" "deps.audit" "gitleaks"] {
      assert (not ($run | str contains $banned)) $"step `($s | get -o name | default '?')` can run on the compat leg and must not run `($banned)`; its if: '($s | get -o if | default '')'"
    }
  }

  for s in $steps {
    assert (not (step-run $s | str contains "mix hex.audit")) $"step `($s | get -o name | default '?')` must not run a bare `mix hex.audit`; audit:hex runs it through scripts/hex-audit.nu"
  }
}

const dependabot_path = ".github/dependabot.yml"

def t7-dependabot [] {
  let cfg = (read $dependabot_path | from yaml)
  assert equal ($cfg | get -o version) 2 $"($dependabot_path) must set version: 2"
  let updates = ($cfg | get -o updates | default [])
  for eco in ["mix" "github-actions"] {
    let hits = ($updates | where {|u| ($u | get -o "package-ecosystem") == $eco })
    assert equal ($hits | length) 1 $"($dependabot_path) updates must have exactly one \"($eco)\" entry; got: ($updates | to nuon)"
    assert equal ($hits.0 | get -o directory) "/" $"the ($eco) entry must set directory: \"/\""
    assert equal ($hits.0 | get -o schedule.interval) "weekly" $"the ($eco) entry must set schedule.interval: \"weekly\""
  }
}

def main [] {
  let results = [
    {name: "T2 wiring", run: {|| t2-wiring }}
    {name: "T3 allow-list parity", run: {|| t3-parity }}
    {name: "T4 doc parity", run: {|| t4-doc }}
    {name: "T5 no orphans", run: {|| t5-orphans }}
    {name: "T5 fixture: doc-sections", run: {|| doc-sections-fixture }}
    {name: "T6 CI workflow", run: {|| t6-ci }}
    {name: "T7 dependabot", run: {|| t7-dependabot }}
  ] | each {|t|
    try {
      do $t.run
      print $"  [ok] ($t.name)"
      {name: $t.name, ok: true}
    } catch {|e|
      print $"  [FAIL] ($t.name): ($e.msg)"
      {name: $t.name, ok: false}
    }
  }
  if ($results | any {|r| not $r.ok }) {
    print "FAIL test:audit-wiring"
    exit 1
  }
  print "PASS test:audit-wiring"
}
