#!/usr/bin/env nu
# test-advisory-doc.nu — overdue review check for docs/security/advisory-exceptions.md.
#
# scripts/advisory-doc.nu does not exist yet. This whole file is RED (fails to
# parse: module not found) until the implementer adds it. The seam cases inject
# `today`; the end-to-end cases use dates far in the past or future, so no case
# depends on the day the test runs.
#
# Interface under test (scripts/advisory-doc.nu):
#   const repo = (path self | path dirname | path dirname)   # top level; path self is parse-time only
#   export def review-overdue [next_review: string, today: string]: nothing -> bool
#       true when next_review (YYYY-MM-DD) is strictly before today
#       (YYYY-MM-DD); equal dates are not overdue. An unparseable or impossible
#       date in either argument RAISES an error; it never returns a value.
#   def main [--doc: path]
#       --doc defaults to <repo>/docs/security/advisory-exceptions.md.
#       Passes `(date now | format date "%Y-%m-%d")` as today. Reads the one
#       `Next review: YYYY-MM-DD` line of each `## <ID>` section. Its final
#       line is `FAIL audit:advisory-doc <IDs> overdue, missing or unparseable
#       Next review (today <date>)`, naming every overdue, missing or
#       unparseable section and no current one, with a non-zero exit;
#       otherwise `PASS audit:advisory-doc`. A doc with no `## ` sections
#       passes. An `## <ID>` section with no `Next review:` line fails.
#   Shared audit script; keep in step with its upstream copy.
#   mise task `audit:advisory-doc` runs `nu scripts/advisory-doc.nu` and is in
#   tasks.ci.depends (asserted by test/test-audit-wiring.nu).
#
# The 90-day gap between Reviewed and Next review is clock-free and is checked
# in test/test-audit-wiring.nu (T4).

use std/assert
use ../scripts/advisory-doc.nu *

const root = path self ..

def section [id: string, next_review: string] {
  [
    $"## ($id)"
    ""
    "### Review trigger"
    ""
    "Reviewed: 2000-01-01"
    $"Next review: ($next_review)"
    ""
    "### Owner"
    ""
    "The repo maintainer."
    ""
  ] | str join "\n"
}

def last-line [text: string] {
  $text | lines | where {|l| ($l | str trim) != "" } | last 1 | get -o 0 | default ""
}

def seam-cases [] {
  assert equal (review-overdue "2026-10-18" "2026-10-19") true "next review before today must be overdue"
  assert equal (review-overdue "2026-10-19" "2026-10-19") false "next review equal to today must not be overdue"
  assert equal (review-overdue "2026-10-20" "2026-10-19") false "next review after today must not be overdue"
  assert equal (review-overdue "2026-12-31" "2027-01-01") true "overdue must compare across a year boundary"
  assert equal (review-overdue "2027-01-17" "2027-01-17") false "a Next review of 2027-01-17 is not overdue on 2027-01-17"

  for bad in ["YYYY-MM-DD" "2027-02-30" "2027-1-17" "" "next quarter"] {
    let r = (try { review-overdue $bad "2027-01-17"; "returned" } catch { "error" })
    assert equal $r "error" $"an unparseable next_review must raise an error, not return a value: '($bad)'"
  }
  for bad in ["not a date" "2027-13-01" ""] {
    let r = (try { review-overdue "2027-01-17" $bad; "returned" } catch { "error" })
    assert equal $r "error" $"an unparseable today must raise an error, not return a value: '($bad)'"
  }
}

def end-to-end-cases [] {
  let dir = (mktemp -d)
  let script = ($root | path join "scripts" "advisory-doc.nu")
  let current = ($dir | path join "current.md")
  let overdue = ($dir | path join "overdue.md")
  let invalid = ($dir | path join "invalid.md")
  let no_exceptions = ($dir | path join "none.md")
  let mixed = ($dir | path join "mixed.md")
  $"# Advisory exceptions\n\n(section 'GHSA-aaaa-aaaa-aaaa' '2999-12-31')\n(section 'GHSA-bbbb-bbbb-bbbb' '2999-12-31')" | save $current
  $"# Advisory exceptions\n\n(section 'GHSA-aaaa-aaaa-aaaa' '2999-12-31')\n(section 'GHSA-bbbb-bbbb-bbbb' '2000-01-02')\n(section 'GHSA-cccc-cccc-cccc' '2000-01-03')" | save $overdue
  $"# Advisory exceptions\n\n(section 'GHSA-aaaa-aaaa-aaaa' '2999-02-30')" | save $invalid

  $"# Advisory exceptions\n\n(section 'GHSA-over-due0-0000' '2000-01-02')\n(section 'GHSA-curr-ent0-0000' '2999-12-31')" | save $mixed
  "# Advisory exceptions\n\nPolicy text only; no exceptions are allow-listed.\n" | save $no_exceptions
  # An ID section with no `Next review:` line, beside a current one.
  let missing = ($dir | path join "missing.md")
  let no_next = (section 'GHSA-miss-ing0-0000' '2999-12-31' | lines | where {|l| not ($l | str starts-with "Next review:") } | str join "\n")
  $"# Advisory exceptions\n\n($no_next)\n(section 'GHSA-curr-ent0-0000' '2999-12-31')" | save $missing

  let ok = (do { ^nu -n $script --doc $current } | complete)
  let late = (do { ^nu -n $script --doc $overdue } | complete)
  let bad = (do { ^nu -n $script --doc $invalid } | complete)
  let none = (do { ^nu -n $script --doc $no_exceptions } | complete)
  let one_late = (do { ^nu -n $script --doc $mixed } | complete)
  let no_next_review = (do { ^nu -n $script --doc $missing } | complete)
  # No --doc, run from the temp dir: main must read <repo>/docs/security/advisory-exceptions.md.
  let default_doc = (do { cd $dir; ^nu -n $script } | complete)
  rm -rf $dir

  assert equal $ok.exit_code 0 $"a doc with future review dates must pass; stdout: ($ok.stdout) stderr: ($ok.stderr)"
  assert ((last-line $ok.stdout) | str starts-with "PASS audit:advisory-doc") "a current doc must end with PASS audit:advisory-doc"

  assert equal $none.exit_code 0 $"a doc with no exceptions must pass; stdout: ($none.stdout) stderr: ($none.stderr)"
  assert ((last-line $none.stdout) | str starts-with "PASS audit:advisory-doc") "a doc with no exceptions must end with PASS audit:advisory-doc"

  assert ($late.exit_code != 0) "a doc with an overdue Next review must fail"
  let late_line = (last-line $late.stdout)
  assert ($late_line | str starts-with "FAIL audit:advisory-doc") $"an overdue doc must end with FAIL audit:advisory-doc; got: ($late_line)"
  assert ($late_line | str contains "GHSA-bbbb-bbbb-bbbb") "the final FAIL line must name every overdue section (bbbb)"
  assert ($late_line | str contains "GHSA-cccc-cccc-cccc") "the final FAIL line must name every overdue section (cccc)"
  assert (not ($late_line | str contains "GHSA-aaaa-aaaa-aaaa")) "the final FAIL line must not name a current section"

  assert ($one_late.exit_code != 0) "one overdue section among current ones must fail"
  let one_late_line = (last-line $one_late.stdout)
  assert ($one_late_line | str starts-with "FAIL audit:advisory-doc") "a mixed doc must end with FAIL audit:advisory-doc"
  assert ($one_late_line | str contains "GHSA-over-due0-0000") "the mixed FAIL line must name the overdue ID"
  assert (not ($one_late_line | str contains "GHSA-curr-ent0-0000")) "the mixed FAIL line must not name the current ID"

  # The real doc may be current or overdue on the day this runs; either way the
  # output must come from it: PASS, or a FAIL line naming one of its sections.
  let real_ids = (open --raw ($root | path join "docs" "security" "advisory-exceptions.md") | lines | where {|l| $l | str starts-with "## " } | each {|l| $l | str substring 3.. | str trim })
  let read_real = ($default_doc.stdout | lines | any {|l| ($l | str starts-with "PASS audit:advisory-doc") or (($l | str starts-with "FAIL audit:advisory-doc") and ($real_ids | any {|id| $l | str contains $id })) })
  assert $read_real $"without --doc, main must check <repo>/docs/security/advisory-exceptions.md from any cwd; stdout: ($default_doc.stdout) stderr: ($default_doc.stderr)"

  # A missing Next review fails closed; it is never a pass.
  assert (not ($no_next | str contains "Next review:")) "fixture: the missing-section doc must have no Next review line for that section"
  assert ($no_next_review.exit_code != 0) $"a section with no Next review line must fail; stdout: ($no_next_review.stdout)"
  let no_next_line = (last-line $no_next_review.stdout)
  assert ($no_next_line | str starts-with "FAIL audit:advisory-doc") $"a section with no Next review must end with FAIL audit:advisory-doc; got: ($no_next_line)"
  assert ($no_next_line | str contains "GHSA-miss-ing0-0000") "the final FAIL line must name the section with no Next review"
  assert ($no_next_line | str contains "missing") "the final FAIL line must say missing"
  assert (not ($no_next_line | str contains "GHSA-curr-ent0-0000")) "the final FAIL line must not name a current section"

  assert ($bad.exit_code != 0) "an unparseable Next review must fail"
  assert ((last-line $bad.stdout) | str starts-with "FAIL audit:advisory-doc") "an unparseable Next review must end with FAIL audit:advisory-doc"
  assert ((last-line $bad.stdout) | str contains "GHSA-aaaa-aaaa-aaaa") "the final FAIL line must name the section with the unparseable date"
}

def main [] {
  seam-cases
  end-to-end-cases
  print "PASS test:advisory-doc"
}
