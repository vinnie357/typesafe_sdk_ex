#!/usr/bin/env nu
# advisory-doc.nu: fail when an advisory exception's review is overdue (task audit:advisory-doc).
#
# Reads the `Next review: YYYY-MM-DD` line of each `## <ID>` section in
# docs/security/advisory-exceptions.md and fails on any date before today, or one that does not
# parse, or a section with no `Next review:` line. Fenced code blocks (the
# template) and non-ID headings are skipped. The clock-free 90-day gap between Reviewed and
# Next review is checked by test/test-audit-wiring.nu.
#
# Tests: test/test-advisory-doc.nu (review-overdue and main).

const repo = (path self | path dirname | path dirname)
const id_heading_re = '^[A-Z][A-Z0-9]*(-[A-Za-z0-9]+)+$'
const date_re = '^\d{4}-\d{2}-\d{2}$'

# A YYYY-MM-DD date; raises on any other shape or an impossible date.
def parse-day [label: string, value: string]: nothing -> datetime {
  # `into datetime` alone accepts shapes such as 2027-1-17.
  if not ($value =~ $date_re) {
    error make {msg: $"($label) '($value)' is not YYYY-MM-DD"}
  }
  try { $value | into datetime --format "%Y-%m-%d" } catch {
    error make {msg: $"($label) '($value)' is not a valid date"}
  }
}

# true when next_review is strictly before today; equal dates are not overdue.
export def review-overdue [next_review: string, today: string]: nothing -> bool {
  (parse-day "Next review" $next_review) < (parse-day "today" $today)
}

# `## <ID>` sections outside fenced code blocks, each with its body lines.
def id-sections [text: string]: nothing -> list<record<id: string, body: list<string>>> {
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
  $sections
}

# The section's ID when it is overdue, has no Next review line, or its date does not parse, else null.
def check-section [section: record, today: string] {
  let dates = ($section.body | where {|l| $l | str starts-with "Next review:" })
  if ($dates | is-empty) { return $section.id }
  if ($dates | length) > 1 { error make {msg: "more than one Next review line"} }
  let next = ($dates | first | str substring ("Next review:" | str length).. | str trim)
  if (review-overdue $next $today) { $section.id } else { null }
}

def main [--doc: path] {
  let doc_path = ($doc | default ($repo | path join "docs" "security" "advisory-exceptions.md"))
  let today = (date now | format date "%Y-%m-%d")
  let text = (try { open --raw $doc_path } catch {
    print $"FAIL audit:advisory-doc cannot read ($doc_path)"
    exit 1
  })
  let failing = (id-sections $text | each {|s|
    try { check-section $s $today } catch {|e|
      print --stderr $"($s.id): ($e.msg)"
      $s.id
    }
  } | compact)
  if ($failing | is-not-empty) {
    print $"FAIL audit:advisory-doc ($failing | str join ' ') overdue, missing or unparseable Next review \(today ($today)\)"
    exit 1
  }
  print "PASS audit:advisory-doc"
}
