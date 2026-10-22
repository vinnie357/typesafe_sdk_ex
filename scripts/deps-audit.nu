#!/usr/bin/env nu
# deps-audit.nu: gate `mix deps.audit` (mix_audit, mirego advisory DB) for task audit:deps.
#
# mix_audit fails open: it ignores a failed DB clone or pull, reads an unreadable lock as no
# dependencies, and never reports a stale ignore entry. So this script fails closed on its own:
# - the lock is missing, unreadable or holds no packages;
# - the advisory DB is missing or holds no advisories;
# - the project report does not parse;
# - a reported advisory is not in the ignore file, or an ignore entry the DB files under a locked
#   package matches no finding (an ID filed only under unlocked packages is info);
# - the positive control (test/fixtures/deps_audit/positive_control/mix.lock, bandit 1.5.0) does not fail.
# The project run gets no ignore flag, so stale entries stay visible. Its exit code is not a signal:
# mix_audit exits 1 for skipped findings too. Raw JSON goes to the out dir, never to stdout.
# Needs network on a host without a DB clone.
#
# Tests: test/test-deps-audit.nu (decision defs and main).

const repo = (path self | path dirname | path dirname)

# The last stdout line that starts with `{`; mix prints compile lines first on a cold _build.
export def last-json-line [stdout: string]: nothing -> string {
  let hits = ($stdout | lines | where {|l| $l | str starts-with "{" })
  if ($hits | is-empty) { "" } else { $hits | last }
}

# ID lines of a mix_audit ignore file, each with the line directly above it.
export def parse-ignore-file [text: string]: nothing -> list<record<id: string, comment: string>> {
  let ls = ($text | lines)
  $ls | enumerate
    | where {|row| ($row.item | str trim) != "" and not ($row.item | str starts-with "#") }
    | each {|row| {id: $row.item, comment: (if $row.index > 0 { $ls | get ($row.index - 1) } else { "" })} }
}

# The parsed report, or null when it is not a record with `pass` and a `vulnerabilities` list.
def parse-report [report_json: string] {
  let report = (try { $report_json | from json } catch { null })
  if ($report | describe) !~ '^record' { return null }
  if ($report | get -o pass) == null { return null }
  if (($report | get -o vulnerabilities | describe) !~ '^(list|table)') { return null }
  $report
}

def reported-ids [report: record]: nothing -> list<string> {
  $report.vulnerabilities | each {|v| $v | get -o advisory.id | default "" } | where {|i| $i != "" }
}

# Decision for the project run, from its JSON only.
export def deps-audit-verdict [report_json: string, skips: list<string>, db_ids: list<string>]: nothing -> record<pass: bool, reason: string, info: list<string>> {
  let report = (parse-report $report_json)
  if $report == null {
    return {pass: false, reason: "mix deps.audit output is not a JSON report with pass and vulnerabilities", info: []}
  }
  let ids = (reported-ids $report)
  let unskipped = ($ids | where {|i| $i not-in $skips })
  let unreported = ($skips | where {|s| $s not-in $ids })
  let stale = ($unreported | where {|s| $s in $db_ids })
  let info = ($unreported | where {|s| $s not-in $db_ids } | each {|s| $"($s) not in mix_audit DB for a locked package" })
  if ($unskipped | is-not-empty) {
    return {pass: false, reason: $"advisory ($unskipped | str join ', ') is not in the ignore file", info: $info}
  }
  if ($stale | is-not-empty) {
    return {pass: false, reason: $"stale ignore entry ($stale | str join ', '): in the mirego DB but not reported", info: $info}
  }
  {pass: true, reason: "", info: $info}
}

# The positive control must exit 1 and report a bandit vulnerability.
export def control-verdict [exit_code: int, report_json: string]: nothing -> record<pass: bool, reason: string> {
  let report = (parse-report $report_json)
  if $report == null {
    return {pass: false, reason: "positive control output is not a JSON report"}
  }
  let bandit = ($report.vulnerabilities | any {|v| ($v | get -o dependency.package) == "bandit" or ($v | get -o advisory.package) == "bandit" })
  if not $bandit {
    return {pass: false, reason: "positive control reported no bandit advisory; the tool or DB is broken"}
  }
  if $exit_code != 1 {
    return {pass: false, reason: $"positive control exited ($exit_code), expected 1"}
  }
  {pass: true, reason: ""}
}

# A missing DB directory globs to 0 files, so one count covers both cases.
export def db-verdict [advisory_file_count: int]: nothing -> record<pass: bool, reason: string> {
  if $advisory_file_count == 0 {
    {pass: false, reason: "advisory DB missing or empty"}
  } else {
    {pass: true, reason: ""}
  }
}

# Package names of the top-level `"<name>": {` entries of a mix.lock.
export def lock-packages [lock_text: string]: nothing -> list<string> {
  $lock_text | lines | parse --regex '^  "(?<name>[^"]+)": \{' | get name
}

# IDs of the DB entries filed under a locked package: an ID filed only under
# packages the lock does not hold can never be reported, so it is info, not stale.
export def locked-db-ids [db_entries: list<record<id: string, package: string>>, locked_packages: list<string>]: nothing -> list<string> {
  $db_entries | where {|e| $e.package in $locked_packages } | get id | uniq
}

# One `<package> <version> <ID> <severity> <status>` line per finding and per unreported skip.
def summary-lines [report, skips: list<string>, db_ids: list<string>]: nothing -> list<string> {
  if $report == null { return [] }
  let findings = ($report.vulnerabilities | each {|v|
    let id = ($v | get -o advisory.id | default "-")
    let pkg = ($v | get -o dependency.package | default ($v | get -o advisory.package) | default "-")
    let ver = ($v | get -o dependency.version | default "-")
    let sev = ($v | get -o advisory.severity | default "-")
    let status = if $id in $skips { "skipped" } else { "unskipped" }
    $"($pkg) ($ver) ($id) ($sev) ($status)"
  })
  let ids = (reported-ids $report)
  let others = ($skips | where {|s| $s not-in $ids } | each {|s|
    let status = if $s in $db_ids { "stale" } else { "info" }
    $"- - ($s) - ($status)"
  })
  $findings | append $others
}

def print-stderr [run: record] {
  if ($run.stderr | str trim) != "" { print --stderr $run.stderr }
}

# The lock's package names, or null when the lock is missing, unreadable or holds no packages.
def read-lock-packages [lock_path: path] {
  if not ($lock_path | path exists) { return null }
  let text = (try { open --raw $lock_path } catch { null })
  if $text == null { return null }
  let packages = (lock-packages $text)
  if ($packages | is-empty) { null } else { $packages }
}

def main [--ignore-file: path, --control-dir: path, --out-dir: path, --lock-file: path] {
  let ignore_path = ($ignore_file | default ($repo | path join ".mix-audit-ignore"))
  let control_path = ($control_dir | default ($repo | path join "test" "fixtures" "deps_audit" "positive_control"))
  let out = ($out_dir | default ($repo | path join "tmp"))
  let lock_path = ($lock_file | default ($repo | path join "mix.lock"))
  let db = ($env.HOME | path join ".local" "share" "elixir-security-advisories-mirego")
  mkdir $out

  # The project run syncs the DB, so the DB is read after it.
  let project = (^mix deps.audit --format=json | complete)
  let control = (^mix deps.audit $"--path=($control_path)" --format=json | complete)
  print-stderr $project
  print-stderr $control
  let project_json = (last-json-line $project.stdout)
  let control_json = (last-json-line $control.stdout)
  $project_json | save -f ($out | path join "deps-audit.json")
  $control_json | save -f ($out | path join "deps-audit-control.json")

  let db_entries = if ($db | path exists) {
    glob ($db | path join "packages" "**" "*.yml") | each {|f| {id: ($f | path parse | get stem), package: ($f | path dirname | path basename)} }
  } else { [] }
  let locked = (read-lock-packages $lock_path)
  let db_ids = (locked-db-ids $db_entries ($locked | default []))
  let db_date = if ($db | path exists) {
    let log = (^git -C $db log -1 --format=%cs | complete)
    if $log.exit_code == 0 and ($log.stdout | str trim) != "" { $log.stdout | str trim } else { "unknown" }
  } else { "unknown" }

  let ignore = if ($ignore_path | path exists) { open --raw $ignore_path } else { null }
  let skips = if $ignore == null { [] } else { parse-ignore-file $ignore | get -o id | default [] }

  let db_v = (db-verdict ($db_entries | length))
  let project_v = (deps-audit-verdict $project_json $skips $db_ids)
  let control_v = (control-verdict $control.exit_code $control_json)

  summary-lines (parse-report $project_json) $skips $db_ids | each {|l| print $l } | ignore
  $project_v.info | each {|i| print $"INFO audit:deps ($i)" } | ignore

  let reason = if $ignore == null {
    $"ignore file not found: ($ignore_path)"
  } else if $locked == null {
    $"mix.lock unreadable: ($lock_path)"
  } else if not $db_v.pass {
    $db_v.reason
  } else if not $project_v.pass {
    $project_v.reason
  } else if not $control_v.pass {
    $control_v.reason
  } else { "" }

  if $reason != "" {
    print $"FAIL audit:deps db=($db_date) ($reason)"
    exit 1
  }
  print $"PASS audit:deps db=($db_date)"
}
