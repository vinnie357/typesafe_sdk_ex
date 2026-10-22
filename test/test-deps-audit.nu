#!/usr/bin/env nu
# test-deps-audit.nu — T1: tests for scripts/deps-audit.nu, the mix_audit gate.
#
# scripts/deps-audit.nu does not exist yet. This whole file is RED (fails to
# parse: module not found) until the implementer adds it. No network, no real
# `mix` call: the seam cases use fixture JSON, and the end-to-end cases run the
# script against a fake `mix` on PATH and a fake advisory DB under a temp HOME.
# Every end-to-end run passes fixture locks through --lock-file, except the
# `default` case. Only the `default` case reads the live .mix-audit-ignore and
# mix.lock (to prove the default paths); no case writes the repo's tmp/.
#
# Interface under test (scripts/deps-audit.nu):
#   const repo = (path self | path dirname | path dirname)   # top level; path self is parse-time only
#   def main [--ignore-file: path, --control-dir: path, --out-dir: path, --lock-file: path]
#       Defaults, built from $repo, never the cwd:
#         --ignore-file  <repo>/.mix-audit-ignore
#         --control-dir  <repo>/test/fixtures/deps_audit/positive_control
#         --out-dir      <repo>/tmp
#         --lock-file    <repo>/mix.lock
#       A missing or unreadable lock, or a lock with 0 parsed packages, fails:
#       `FAIL audit:deps db=<date> mix.lock unreadable: <path>`.
#       It ranks after the missing ignore file and before the DB check.
#       No `try { ... } catch { "" }` around the lock read.
#   export def last-json-line [stdout: string]: nothing -> string
#       Last stdout line that starts with `{`; "" when there is none.
#   export def parse-ignore-file [text: string]: nothing -> list<record<id: string, comment: string>>
#       ID lines are lines that are neither `#` lines nor blank. `comment` is the
#       `#` line directly above the ID line, verbatim.
#   export def deps-audit-verdict [report_json: string, skips: list<string>, db_ids: list<string>]: nothing -> record<pass: bool, reason: string, info: list<string>>
#       No exit code. Fails on unparseable JSON or JSON without `pass` /
#       `vulnerabilities`, or whose `vulnerabilities` is not a list; on a reported advisory.id not in skips (reason names
#       the ID); on a stale skip, an ID in db_ids that is not reported (reason
#       names the ID and says "stale"). A skip absent from db_ids passes and adds
#       an info entry naming the ID. db_ids is the output of locked-db-ids, not
#       every ID in the DB.
#   export def lock-packages [lock_text: string]: nothing -> list<string>
#       Package names of the top-level `"<name>": {` entries of a mix.lock.
#   export def locked-db-ids [db_entries: list<record<id: string, package: string>>, locked_packages: list<string>]: nothing -> list<string>
#       IDs of the DB entries whose package is in locked_packages.
#
# Stale: a skip is stale only when the mirego DB
# files that ID under packages/<pkg>/ for a <pkg> present in mix.lock, and the
# project report does not list it. An ID filed only under packages that are not
# in mix.lock prints INFO and passes, the same as an ID absent from the DB.
# Live case: GHSA-w4f7-4cxr-rv3c is filed under packages/gun/, and this repo does
# not lock gun.
#   export def control-verdict [exit_code: int, report_json: string]: nothing -> record<pass: bool, reason: string>
#       Passes only on exit 1 with a parseable report holding a bandit vulnerability.
#   export def db-verdict [advisory_file_count: int]: nothing -> record<pass: bool, reason: string>
#       Fails on 0 files; the reason says "empty".
#
# `main` contract (end-to-end block; task `audit:deps`):
# - DB is $env.HOME/.local/share/elixir-security-advisories-mirego. It globs
#   <db>/packages/**/*.yml once. Each file gives one db entry: id = basename
#   without .yml, package = its parent directory name. The count passed to
#   db-verdict is that list's length. A missing DB directory fails.
# - db_ids = locked-db-ids(db entries, lock-packages(<lock-file>)).
# - runs `mix` exactly twice: `mix deps.audit --format=json` (project; never
#   `--ignore-file` or `--ignore-advisory-ids`), then
#   `mix deps.audit --path=<control-dir> --format=json` (positive control).
# - JSON is taken with last-json-line; the project exit code is not a signal.
# - the fixture DB commit is dated 2024-01-02, so `db=` must come from git, not the clock.
# - writes <out-dir>/deps-audit.json and <out-dir>/deps-audit-control.json,
#   creating <out-dir> when missing. No other file.
# - prints one line per finding:
#   `<package> <version> <ID> <severity> <skipped|unskipped|stale|info>`, with
#   `-` for any unknown field (stale and info entries have no reported finding),
#   `INFO audit:deps <id> not in mix_audit DB` per absent skip,
#   `INFO audit:deps <id> ...` per skip filed only under unlocked packages, and a final
#   line `PASS audit:deps db=<YYYY-MM-DD>` or
#   `FAIL audit:deps db=<YYYY-MM-DD> <first finding>`, the date from
#   `git -C <db> log -1 --format=%cs`. A blind control prints
#   `FAIL audit:deps db=<date> positive control ...`. Exits non-zero on FAIL.
#
# JSON fixtures follow the mix_audit 2.1.5 output shape, captured from a real
# run on test/fixtures/deps_audit/positive_control.

use std/assert
use ../scripts/deps-audit.nu *

const root = path self ..

const cowlib_id = "GHSA-w4f7-4cxr-rv3c"
const bandit_id = "GHSA-375f-4r2h-f99j"
const mint_id = "GHSA-2p26-p43x-fhp8"

const clean_json = '{"pass":true,"vulnerabilities":[]}'
const bandit_json = '{"pass":false,"vulnerabilities":[{"advisory":{"id":"GHSA-375f-4r2h-f99j","package":"bandit","severity":"high"},"dependency":{"package":"bandit","version":"1.5.0"}}]}'

def comment-for [id: string] {
  $"# ($id) https://github.com/vinnie357/typesafe_sdk_ex/issues/29 docs/security/advisory-exceptions.md#($id | str lowercase)"
}

# ID lines of the live .mix-audit-ignore; [] when it is missing.
def live-skip-ids [] {
  let file = ($root | path join ".mix-audit-ignore")
  if not ($file | path exists) { return [] }
  open --raw $file | lines | where {|l| not (($l | str starts-with "#") or ($l | str trim | is-empty)) }
}

def vuln [package: string, version: string, id: string, severity: string] {
  {
    advisory: {
      id: $id
      title: $"($package) advisory"
      severity: $severity
      url: $"https://github.com/advisories/($id)"
      package: $package
      disclosure_date: "2026-05-07"
      vulnerable_version_ranges: ["< 99.0.0"]
      first_patched_versions: ["99.0.0"]
      description: "fixture"
    }
    dependency: {version: $version, lockfile: "/fixture/mix.lock", package: $package}
  }
}

def report [vulns: list] {
  {pass: ($vulns | is-empty), vulnerabilities: $vulns} | to json --raw
}

def has-line [text: string, needle: string] {
  $text | lines | any {|l| $l | str contains $needle }
}

def last-line [text: string] {
  $text | lines | where {|l| ($l | str trim) != "" } | last
}

def seam-cases [] {
  let clean = (report [])
  let cowlib = (vuln "cowlib" "2.21.0" $cowlib_id "moderate")
  let bandit = (vuln "bandit" "1.10.3" $bandit_id "moderate")

  # -------- deps-audit-verdict --------
  let v = (deps-audit-verdict $clean [] [])
  assert equal $v.pass true "clean report with no skips must pass"

  let v = (deps-audit-verdict (report [$bandit]) [] [$bandit_id])
  assert equal $v.pass false "an unskipped vulnerability must fail"
  assert ($v.reason | str contains $bandit_id) "unskipped failure reason must name the ID"

  let v = (deps-audit-verdict (report [$cowlib]) [$cowlib_id] [$cowlib_id])
  assert equal $v.pass true "a skipped vulnerability must pass"

  let v = (deps-audit-verdict $clean [$bandit_id] [$bandit_id])
  assert equal $v.pass false "a skip that is in the DB but not reported is stale and must fail"
  assert ($v.reason | str contains $bandit_id) "stale failure reason must name the ID"
  assert ($v.reason | str contains "stale") "stale failure reason must say stale"

  # A stale skip beside a reported, skipped finding: the stale check must not
  # depend on an empty report.
  let v = (deps-audit-verdict $bandit_json [$bandit_id $mint_id] [$bandit_id $mint_id])
  assert equal $v.pass false "a stale skip must fail even when another skipped finding is reported"
  assert ($v.reason | str contains $mint_id) "the stale failure reason must name the stale ID beside a reported finding"
  assert ($v.reason | str contains "stale") "the stale failure reason must say stale beside a reported finding"

  let v = (deps-audit-verdict $clean [$cowlib_id] [$bandit_id])
  assert equal $v.pass true "a skip absent from the DB must pass"
  assert ($v.info | any {|l| $l | str contains $cowlib_id }) "a skip absent from the DB must add an INFO entry naming it"

  let v = (deps-audit-verdict (report [$cowlib]) [$cowlib_id] [$bandit_id])
  assert equal $v.pass true "a reported, skipped ID absent from the DB must pass"

  # Exit code is not an input: mix_audit exits 1 even when every finding is skipped.
  let v = (deps-audit-verdict (report [$cowlib]) [$cowlib_id] [$cowlib_id])
  assert equal $v.pass true "a report holding only a skipped vulnerability must pass (exit 1 is not a signal)"

  for bad in ["not json" "{}" "" '{"pass":true}' '{"vulnerabilities":[]}'] {
    let v = (deps-audit-verdict $bad [] [])
    assert equal $v.pass false $"unparseable or incomplete JSON must fail: '($bad)'"
  }

  # `vulnerabilities` must be a list; null or a record fails closed.
  assert equal (deps-audit-verdict '{"pass":true,"vulnerabilities":null}' [] []).pass false "a null vulnerabilities field must fail, even with pass true"
  assert equal (deps-audit-verdict '{"vulnerabilities":{}}' [] []).pass false "a record vulnerabilities field without pass must fail"

  # -------- last-json-line --------
  let noisy = "==> mix_audit\nCompiling 14 files (.ex)\nGenerated mix_audit app\n{\"pass\":true,\"vulnerabilities\":[]}\n"
  assert equal (last-json-line $noisy) '{"pass":true,"vulnerabilities":[]}' "last-json-line must return the JSON line after compile noise"
  assert equal (deps-audit-verdict (last-json-line $noisy) [] []).pass true "the extracted JSON line must pass"
  assert equal (deps-audit-verdict $noisy [] []).pass false "whole noisy stdout must fail as unparseable (why last-json-line exists)"
  assert equal (last-json-line "==> mix_audit\nCompiling 14 files (.ex)\n") "" "last-json-line must return an empty string when no line starts with {"
  assert equal (deps-audit-verdict (last-json-line "==> mix_audit\n") [] []).pass false "an empty extraction must fail"
  assert equal (last-json-line "{\"a\":1}\nnoise\n{\"pass\":true,\"vulnerabilities\":[]}\n") '{"pass":true,"vulnerabilities":[]}' "last-json-line must take the last { line"

  # -------- control-verdict --------
  let control = (report [(vuln "bandit" "1.5.0" $bandit_id "moderate")])
  assert equal (control-verdict 1 $control).pass true "control exit 1 with a bandit vulnerability must pass"
  let v = (control-verdict 0 $clean)
  assert equal $v.pass false "control exit 0 with no findings means a blind scanner and must fail"
  assert equal (control-verdict 1 "not json").pass false "control with unparseable JSON must fail"
  assert equal (control-verdict 1 (report [(vuln "mint" "1.8.0" "GHSA-mint-0000-0000" "low")])).pass false "control without a bandit finding must fail"
  assert equal (control-verdict 0 $control).pass false "control must exit 1; exit 0 must fail"
  # The control passes only on exit 1.
  assert equal (control-verdict 1 '{"pass":false,"vulnerabilities":null}').pass false "control with a null vulnerabilities field must fail"
  assert equal (control-verdict 2 $control).pass false "control exit 2 means mix_audit errored and must fail, even with a bandit report"

  # -------- db-verdict --------
  let v = (db-verdict 0)
  assert equal $v.pass false "an empty advisory DB must fail"
  assert ($v.reason | str contains "empty") "empty-DB failure reason must say empty"
  assert equal (db-verdict 57).pass true "a populated advisory DB must pass"

  # -------- lock-packages / locked-db-ids --------
  let control_lock = (open --raw ($root | path join "test" "fixtures" "deps_audit" "positive_control" "mix.lock"))
  assert equal (lock-packages $control_lock) ["bandit"] "lock-packages must read the package name of each top-level lock entry"
  let two_lock = "%{\n  \"bandit\": {:hex, :bandit, \"1.5.0\", \"x\", [:mix], [{:plug, \"~> 1.14\", [hex: :plug, repo: \"hexpm\", optional: false]}], \"hexpm\", \"y\"},\n  \"mint\": {:hex, :mint, \"1.8.0\", \"x\", [:mix], [], \"hexpm\", \"y\"},\n}\n"
  assert equal (lock-packages $two_lock | sort) ["bandit" "mint"] "lock-packages must list every entry and not the names inside dependency lists (plug)"

  let entries = [
    {id: $bandit_id, package: "bandit"}
    {id: $mint_id, package: "mint"}
    {id: $cowlib_id, package: "gun"}
  ]
  assert equal (locked-db-ids $entries ["bandit" "mint"] | sort) ([$bandit_id $mint_id] | sort) "locked-db-ids must drop IDs filed only under unlocked packages"
  assert equal (locked-db-ids [{id: $cowlib_id, package: "gun"} {id: $cowlib_id, package: "cowlib"}] ["cowlib"]) [$cowlib_id] "an ID filed under any locked package counts"

  # An ID in the DB only under an unlocked package is INFO, not stale.
  let v = (deps-audit-verdict $clean [$cowlib_id] (locked-db-ids $entries ["bandit" "mint"]))
  assert equal $v.pass true "a skip filed only under an unlocked package must pass"
  assert ($v.info | any {|l| $l | str contains $cowlib_id }) "a skip filed only under an unlocked package must add an INFO entry"

  # The same ID under a locked package and unreported is still stale.
  let v = (deps-audit-verdict $clean [$mint_id] (locked-db-ids $entries ["bandit" "mint"]))
  assert equal $v.pass false "a skip filed under a locked package and not reported must stay stale"
  assert ($v.reason | str contains $mint_id) "the stale reason must name the ID"

  # -------- parse-ignore-file --------
  let comment = $"# ($cowlib_id) https://github.com/vinnie357/typesafe_sdk_ex/issues/29 docs/security/advisory-exceptions.md#ghsa-w4f7-4cxr-rv3c"
  let planned = $"($comment)\n($cowlib_id)\n"
  assert equal (parse-ignore-file $planned) [{id: $cowlib_id, comment: $comment}] "parse-ignore-file must return the ID with the comment above it"
  assert equal (parse-ignore-file $"\n\n($planned)\n\n") [{id: $cowlib_id, comment: $comment}] "parse-ignore-file must drop blank lines"
  let two = $"($comment)\n($cowlib_id)\n\n# ($bandit_id) note\n($bandit_id)\n"
  assert equal (parse-ignore-file $two | get id) [$cowlib_id $bandit_id] "parse-ignore-file must return every ID line in order"
  assert equal (parse-ignore-file $two | get comment | last) $"# ($bandit_id) note" "each ID must pair with the comment directly above it"
  assert equal (parse-ignore-file "# only a comment\n") [] "a comment-only file holds no IDs"
}

def end-to-end-cases [] {
  let dir = (mktemp -d)
  let home = ($dir | path join "home")
  let db = ($home | path join ".local" "share" "elixir-security-advisories-mirego")
  let calls = ($dir | path join "calls.log")
  let script = ($root | path join "scripts" "deps-audit.nu")

  # Fake mirego DB: two advisories, one git commit with an explicit identity
  # (the temp HOME has no ~/.gitconfig).
  let bandit_yml = ($db | path join "packages" "bandit" $"($bandit_id).yml")
  let mint_yml = ($db | path join "packages" "mint" $"($mint_id).yml")
  mkdir ($bandit_yml | path dirname) ($mint_yml | path dirname)
  $"---\nid: ($bandit_id)\npackage: bandit\n" | save $bandit_yml
  $"---\nid: ($mint_id)\npackage: mint\n" | save $mint_yml
  ^git -C $db init -q
  ^git -C $db add -A
  # Pinned commit date: main must print the DB's commit date, never the clock.
  with-env {GIT_AUTHOR_DATE: "2024-01-02T00:00:00Z", GIT_COMMITTER_DATE: "2024-01-02T00:00:00Z"} {
    ^git -C $db -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m fixture
  }
  let db_date = (^git -C $db log -1 --format=%cs | str trim)
  assert equal $db_date "2024-01-02" "the fixture DB commit date must be pinned to 2024-01-02"

  # Temp ignore files; each ID line has its `# <ID> <issue URL> <docs anchor>` comment.
  let ignore_empty = ($dir | path join "ignore-empty")
  let ignore_skip = ($dir | path join "ignore-skip")
  let ignore_stale = ($dir | path join "ignore-stale")
  let ignore_skip_stale = ($dir | path join "ignore-skip-stale")
  let ignore_absent = ($dir | path join "ignore-absent")
  "# mix_audit skips (fixture)\n" | save $ignore_empty
  $"# mix_audit skips \(fixture\)\n(comment-for $bandit_id)\n($bandit_id)\n" | save $ignore_skip
  $"# mix_audit skips \(fixture\)\n(comment-for $mint_id)\n($mint_id)\n" | save $ignore_stale
  $"# mix_audit skips \(fixture\)\n(comment-for $bandit_id)\n($bandit_id)\n(comment-for $mint_id)\n($mint_id)\n" | save $ignore_skip_stale
  $"# mix_audit skips \(fixture\)\n(comment-for $cowlib_id)\n($cowlib_id)\n" | save $ignore_absent

  $"($clean_json)\n" | save ($dir | path join "clean.json")
  $"($bandit_json)\n" | save ($dir | path join "bandit.json")
  # FAKE_AUDIT=null-vulns prints a report whose vulnerabilities is null.
  "{\"pass\":true,\"vulnerabilities\":null}\n" | save ($dir | path join "null-vulns.json")

  # Fake `mix`: logs every argv; exits 99 on an ignore flag (a `main` that
  # forwards the ignore list hides stale skips) and on any non-deps.audit call.
  # The control (--path basename positive_control) reports bandit with exit 1
  # unless FAKE_CONTROL=pass (FAKE_CONTROL unset is the failing control).
  let shim = ($dir | path join "mix")
  [
    "#!/bin/sh"
    $"D='($dir)'"
    "echo \"$*\" >> \"$D/calls.log\""
    "[ \"$1\" = deps.audit ] || exit 99"
    "ctl=no; prev="
    "for a in \"$@\"; do"
    "  case \"$a\" in"
    "    --ignore-file|--ignore-file=*|--ignore-advisory-ids|--ignore-advisory-ids=*) exit 99 ;;"
    "    --path=*) [ -d \"${a#--path=}\" ] || exit 98; [ \"$(basename \"${a#--path=}\")\" = positive_control ] && ctl=yes ;;"
    "  esac"
    "  if [ \"$prev\" = --path ]; then [ -d \"$a\" ] || exit 98; [ \"$(basename \"$a\")\" = positive_control ] && ctl=yes; fi"
    "  prev=\"$a\""
    "done"
    "if [ $ctl = yes ]; then"
    "  if [ \"$FAKE_CONTROL\" = pass ]; then cat \"$D/clean.json\"; exit 0; fi"
    "  cat \"$D/bandit.json\"; exit 1"
    "fi"
    "echo '==> mix_audit'"
    "echo 'Compiling 14 files (.ex)'"
    "case \"$FAKE_AUDIT\" in"
    "  clean) cat \"$D/clean.json\"; exit 0 ;;"
    "  skipped|unskipped) cat \"$D/bandit.json\"; exit 1 ;;"
    "  null-vulns) cat \"$D/null-vulns.json\"; exit 0 ;;"
    "esac"
    "exit 99"
  ] | str join "\n" | save $shim
  ^chmod +x $shim

  # Fixture locks. lock_bm locks bandit and mint, the two
  # packages the fake DB files advisories under; it is the lock for every run
  # but `default`. lock_m locks only mint. Neither locks gun. Their names do
  # not contain "mix.lock", so a FAIL line naming mix.lock names it from the
  # reason text, not from the path.
  let lock_bm = ($dir | path join "bandit-mint.lock")
  let lock_m = ($dir | path join "mint-only.lock")
  let lock_empty = ($dir | path join "empty.lock")
  let lock_absent = ($dir | path join "absent.lock")
  "%{\n  \"bandit\": {:hex, :bandit, \"1.5.0\", \"x\", [:mix], [{:plug, \"~> 1.14\", [hex: :plug, repo: \"hexpm\", optional: false]}], \"hexpm\", \"y\"},\n  \"mint\": {:hex, :mint, \"1.8.0\", \"x\", [:mix], [], \"hexpm\", \"y\"},\n}\n" | save $lock_bm
  "%{\n  \"mint\": {:hex, :mint, \"1.8.0\", \"x\", [:mix], [], \"hexpm\", \"y\"},\n}\n" | save $lock_m
  "" | save $lock_empty
  assert equal (lock-packages (open --raw $lock_bm) | sort) ["bandit" "mint"] "fixture: lock_bm must lock bandit and mint"
  assert equal (lock-packages (open --raw $lock_m)) ["mint"] "fixture: lock_m must lock only mint"
  let ignore_absent_file = ($dir | path join "no-such-ignore-file")

  let path = ($env.PATH | prepend $dir)
  # ignore == "" runs without --ignore-file, so main uses its <repo>/.mix-audit-ignore default.
  # lock == "" runs without --lock-file, so main uses its <repo>/mix.lock default.
  let run = {|name: string, ignore: string, audit: string, control: string, lock: string|
    rm -f $calls
    let out = ($dir | path join "out" $name)
    let ignore_flags = if $ignore == "" { [] } else { ["--ignore-file" $ignore] }
    let lock_flags = if $lock == "" { [] } else { ["--lock-file" $lock] }
    let flags = ($ignore_flags | append $lock_flags)
    let r = (do {
      hide-env -i FAKE_CONTROL
      let fake = if $control == "" { {FAKE_AUDIT: $audit} } else { {FAKE_AUDIT: $audit, FAKE_CONTROL: $control} }
      # cwd is the temp dir, so a cwd-relative default path fails the default case.
      cd $dir
      with-env ({PATH: $path, HOME: $home} | merge $fake) { ^nu -n $script ...$flags --out-dir $out }
    } | complete)
    let call_lines = if ($calls | path exists) { open --raw $calls | lines } else { [] }
    let files = if ($out | path exists) { ls $out | get name | path basename | sort } else { [] }
    $r | merge {out: $out, calls: $call_lines, files: $files}
  }

  let clean = (do $run "clean" $ignore_empty "clean" "" $lock_bm)
  let clean_project = (open --raw ($clean.out | path join "deps-audit.json"))
  let clean_control = (open --raw ($clean.out | path join "deps-audit-control.json"))
  let skipped = (do $run "skipped" $ignore_skip "skipped" "" $lock_bm)
  let unskipped = (do $run "unskipped" $ignore_empty "unskipped" "" $lock_bm)
  let stale = (do $run "stale" $ignore_stale "clean" "" $lock_bm)
  let skip_stale = (do $run "skip-stale" $ignore_skip_stale "skipped" "" $lock_bm)
  let info = (do $run "info" $ignore_absent "clean" "" $lock_bm)
  let null_vulns = (do $run "null-vulns" $ignore_empty "null-vulns" "" $lock_bm)
  # --lock-file is the lock the stale check reads. The same
  # unreported bandit skip is stale under a lock that holds bandit and INFO
  # under a lock that does not.
  let lock_flag_stale = (do $run "lock-flag-stale" $ignore_skip "clean" "" $lock_bm)
  let lock_flag_info = (do $run "lock-flag-info" $ignore_skip "clean" "" $lock_m)
  # A missing or empty lock fails closed; a missing ignore file outranks it.
  let lock_missing = (do $run "lock-missing" $ignore_empty "clean" "" $lock_absent)
  let lock_empty_run = (do $run "lock-empty" $ignore_empty "clean" "" $lock_empty)
  # A lock that exists but cannot be read fails closed too. It
  # holds lock_bm's text, so only the read can fail. root reads a mode-000
  # file, so the case is skipped under uid 0. Mode is restored before cleanup.
  let as_root = ((^id -u | str trim) == "0")
  let lock_unreadable = ($dir | path join "unreadable.lock")
  let lock_unreadable_run = if $as_root { null } else {
    ^cp $lock_bm $lock_unreadable
    ^chmod 000 $lock_unreadable
    let r = (do $run "lock-unreadable" $ignore_empty "clean" "" $lock_unreadable)
    ^chmod 644 $lock_unreadable
    $r
  }
  let rank = (do $run "rank" $ignore_absent_file "clean" "" $lock_absent)
  # The cowlib ID filed under packages/gun/, which the fixture lock does not hold.
  let gun_yml = ($db | path join "packages" "gun" $"($cowlib_id).yml")
  mkdir ($gun_yml | path dirname)
  $"---\nid: ($cowlib_id)\npackage: gun\n" | save $gun_yml
  let unlocked = (do $run "unlocked" $ignore_absent "clean" "" $lock_bm)
  rm -rf ($gun_yml | path dirname)
  let default_ignore = (do $run "default" "" "clean" "" "")
  let blind = (do $run "blind" $ignore_empty "clean" "pass" $lock_bm)
  rm $bandit_yml $mint_yml
  let empty_db = (do $run "empty" $ignore_empty "clean" "" $lock_bm)
  # A missing lock outranks the DB check.
  let lock_before_db = (do $run "lock-before-db" $ignore_empty "clean" "" $lock_absent)
  rm -rf $db
  let missing_db = (do $run "missing" $ignore_empty "clean" "" $lock_bm)
  rm -rf $dir

  # clean: PASS with the DB date, exactly two mix calls, no ignore flags, JSON in --out-dir.
  assert equal $clean.exit_code 0 $"clean audit must exit 0; stdout: ($clean.stdout) stderr: ($clean.stderr)"
  assert equal (last-line $clean.stdout) $"PASS audit:deps db=($db_date)" "clean audit must end with PASS audit:deps db=<DB commit date>"
  assert (not (has-line $clean.stdout "INFO audit:deps")) "a clean audit with no skips must print no INFO line"
  let audit_calls = ($clean.calls | where {|l| $l | str contains "deps.audit" })
  assert equal ($audit_calls | length) 2 $"main must run mix deps.audit exactly twice; calls: ($clean.calls)"
  assert equal ($clean.calls | length) 2 $"main must make no other mix call; calls: ($clean.calls)"
  assert (not ($audit_calls.0 | str contains "--path")) "the first deps.audit call must be the project run, without --path"
  assert ($audit_calls.1 | str contains "--path") "the second deps.audit call must pass --path"
  assert ($audit_calls.1 | str contains "positive_control") "the second deps.audit call must target the positive_control fixture"
  for c in $audit_calls {
    assert (not ($c | str contains "--ignore-file")) "main must never pass --ignore-file to mix (it hides stale skips)"
    assert (not ($c | str contains "--ignore-advisory-ids")) "main must never pass --ignore-advisory-ids to mix (it hides stale skips)"
  }
  assert equal ($clean_project | from json) ($clean_json | from json) "<out-dir>/deps-audit.json must hold the project JSON"
  assert equal ($clean_control | from json) ($bandit_json | from json) "<out-dir>/deps-audit-control.json must hold the control JSON"
  assert equal $clean.files ["deps-audit-control.json" "deps-audit.json"] "main must write exactly the two JSON files to --out-dir (no marker files)"

  # skipped: the finding is in the DB and on the skip list; mix exited 1, the gate passes.
  assert equal $skipped.exit_code 0 $"a report with only a skipped finding must pass although mix exited 1; stdout: ($skipped.stdout)"
  assert (has-line $skipped.stdout $"bandit 1.5.0 ($bandit_id) high skipped") "a skipped finding must print `<package> <version> <ID> <severity> skipped`"
  assert equal (last-line $skipped.stdout) $"PASS audit:deps db=($db_date)" "skipped audit must end with PASS audit:deps db=<date>"
  assert (not (has-line $skipped.stdout "INFO audit:deps")) "a skip that is in the DB must not print INFO"

  # unskipped: a finding not on the skip list fails and is named.
  assert ($unskipped.exit_code != 0) "an unskipped finding must exit non-zero"
  assert (has-line $unskipped.stdout $"bandit 1.5.0 ($bandit_id) high unskipped") "an unskipped finding must print `<package> <version> <ID> <severity> unskipped`"
  assert ((last-line $unskipped.stdout) | str starts-with $"FAIL audit:deps db=($db_date)") "an unskipped finding must end with FAIL audit:deps db=<date>"
  assert ((last-line $unskipped.stdout) | str contains $bandit_id) "the FAIL line must name the unskipped ID"

  # stale: a skip that is in the DB but not reported fails.
  assert ($stale.exit_code != 0) "a stale skip must exit non-zero"
  assert (has-line $stale.stdout $"- - ($mint_id) - stale") "a stale skip must print `- - <ID> - stale`"
  let stale_line = (last-line $stale.stdout)
  assert ($stale_line | str starts-with $"FAIL audit:deps db=($db_date)") $"a stale skip must end with FAIL audit:deps db=<date>; got: ($stale_line)"
  assert ($stale_line | str contains $mint_id) "the stale FAIL line must name the ID"
  assert ($stale_line | str contains "stale") "the stale FAIL line must say stale"

  # skip + stale: a reported, skipped finding does not hide a stale entry.
  assert ($skip_stale.exit_code != 0) $"a stale skip beside a skipped finding must exit non-zero; stdout: ($skip_stale.stdout)"
  assert (has-line $skip_stale.stdout $"bandit 1.5.0 ($bandit_id) high skipped") "the skipped finding must still print `<package> <version> <ID> <severity> skipped`"
  assert (has-line $skip_stale.stdout $"- - ($mint_id) - stale") "the stale skip must print `- - <ID> - stale`"
  let skip_stale_line = (last-line $skip_stale.stdout)
  assert ($skip_stale_line | str starts-with $"FAIL audit:deps db=($db_date)") $"skip + stale must end with FAIL audit:deps db=<date>; got: ($skip_stale_line)"
  assert ($skip_stale_line | str contains $mint_id) "the skip + stale FAIL line must name the stale ID"
  assert ($skip_stale_line | str contains "stale") "the skip + stale FAIL line must say stale"

  # info: a skip absent from the DB (today's cowlib case) passes with INFO.
  assert equal $info.exit_code 0 $"a skip absent from the DB must pass; stdout: ($info.stdout)"
  assert (has-line $info.stdout $"INFO audit:deps ($cowlib_id) not in mix_audit DB") "a skip absent from the DB must print INFO audit:deps <id> not in mix_audit DB"
  assert (has-line $info.stdout $"- - ($cowlib_id) - info") "a skip absent from the DB must print `- - <ID> - info`"
  assert equal (last-line $info.stdout) $"PASS audit:deps db=($db_date)" "info audit must end with PASS audit:deps db=<date>"

  # null vulnerabilities: the gate fails closed with its own FAIL line, not a nushell error.
  assert ($null_vulns.exit_code != 0) $"a report with null vulnerabilities must exit non-zero; stdout: ($null_vulns.stdout)"
  assert (has-line $null_vulns.stdout "FAIL audit:deps") $"a report with null vulnerabilities must print FAIL audit:deps; stdout: ($null_vulns.stdout)"
  assert (not (has-line $"($null_vulns.stdout)\n($null_vulns.stderr)" "Error:")) $"a report with null vulnerabilities must not raise a nushell Error:; stderr: ($null_vulns.stderr)"

  # unlocked: the skip is in the DB only under a package mix.lock does not hold.
  assert (not (open --raw ($root | path join "mix.lock") | str contains '"gun": {')) "precondition: the repo's mix.lock must not lock gun"
  assert equal $unlocked.exit_code 0 $"a skip filed only under an unlocked package must pass; stdout: ($unlocked.stdout)"
  assert (has-line $unlocked.stdout $"INFO audit:deps ($cowlib_id)") "a skip filed only under an unlocked package must print INFO audit:deps <id>"
  assert (has-line $unlocked.stdout $"- - ($cowlib_id) - info") "a skip filed only under an unlocked package must print `- - <ID> - info`"
  assert (not (has-line $unlocked.stdout $"- - ($cowlib_id) - stale")) "a skip filed only under an unlocked package must not print stale"
  assert equal (last-line $unlocked.stdout) $"PASS audit:deps db=($db_date)" "the unlocked case must end with PASS audit:deps db=<date>"

  # --lock-file decides staleness.
  assert ($lock_flag_stale.exit_code != 0) $"an unreported skip filed under a package the --lock-file locks must fail; stdout: ($lock_flag_stale.stdout)"
  assert (has-line $lock_flag_stale.stdout $"- - ($bandit_id) - stale") "an unreported skip under a locked package must print `- - <ID> - stale`"
  let lock_flag_stale_line = (last-line $lock_flag_stale.stdout)
  assert ($lock_flag_stale_line | str starts-with $"FAIL audit:deps db=($db_date)") $"the --lock-file stale case must end with FAIL audit:deps db=<date>; got: ($lock_flag_stale_line)"
  assert ($lock_flag_stale_line | str contains $bandit_id) "the --lock-file stale FAIL line must name the ID"
  assert ($lock_flag_stale_line | str contains "stale") "the --lock-file stale FAIL line must say stale"
  assert equal $lock_flag_info.exit_code 0 $"the same skip must pass when the --lock-file does not lock its package; stdout: ($lock_flag_info.stdout) stderr: ($lock_flag_info.stderr)"
  assert (has-line $lock_flag_info.stdout $"INFO audit:deps ($bandit_id)") "a skip under a package the --lock-file does not lock must print INFO audit:deps <id>"
  assert (has-line $lock_flag_info.stdout $"- - ($bandit_id) - info") "a skip under a package the --lock-file does not lock must print `- - <ID> - info`"
  assert (not (has-line $lock_flag_info.stdout $"- - ($bandit_id) - stale")) "main must read the --lock-file, not <repo>/mix.lock, which locks bandit"
  assert equal (last-line $lock_flag_info.stdout) $"PASS audit:deps db=($db_date)" "the --lock-file info case must end with PASS audit:deps db=<date>"

  # A missing or empty lock fails closed, never as an empty package list.
  for c in [[name r]; ["missing" $lock_missing] ["empty" $lock_empty_run]] {
    assert ($c.r.exit_code != 0) $"a ($c.name) lock must exit non-zero; stdout: ($c.r.stdout)"
    let l = (last-line $c.r.stdout)
    assert ($l | str starts-with $"FAIL audit:deps db=($db_date)") $"a ($c.name) lock must end with FAIL audit:deps db=<date>; got: ($l)"
    assert ($l | str contains "mix.lock") $"the ($c.name)-lock FAIL line must name mix.lock; got: ($l)"
  }
  assert ((last-line $lock_missing.stdout) | str contains "absent.lock") "the missing-lock FAIL line must name the lock path"
  assert ((last-line $lock_empty_run.stdout) | str contains "empty.lock") "the empty-lock FAIL line must name the lock path"
  if $lock_unreadable_run == null {
    print "SKIP unreadable-lock case: running as root, which reads a mode-000 file"
  } else {
    assert ($lock_unreadable_run.exit_code != 0) $"an unreadable lock must exit non-zero; stdout: ($lock_unreadable_run.stdout)"
    let l = (last-line $lock_unreadable_run.stdout)
    assert ($l | str starts-with $"FAIL audit:deps db=($db_date)") $"an unreadable lock must end with FAIL audit:deps db=<date>; got: ($l)"
    assert ($l | str contains "mix.lock") $"the unreadable-lock FAIL line must name mix.lock; got: ($l)"
    assert ($l | str contains "unreadable.lock") $"the unreadable-lock FAIL line must name the lock path; got: ($l)"
  }

  # Rank: a missing ignore file outranks a missing lock.
  assert ($rank.exit_code != 0) $"a missing ignore file and a missing lock must exit non-zero; stdout: ($rank.stdout)"
  let rank_line = (last-line $rank.stdout)
  assert ($rank_line | str starts-with "FAIL audit:deps") $"the rank case must end with FAIL audit:deps; got: ($rank_line)"
  assert ($rank_line | str contains "no-such-ignore-file") $"with both missing, the FAIL line must name the ignore file; got: ($rank_line)"
  assert (not ($rank_line | str contains "absent.lock")) $"with both missing, the FAIL line must not name the lock; got: ($rank_line)"

  # Rank: a missing lock outranks an empty DB.
  assert ($lock_before_db.exit_code != 0) "a missing lock with an empty DB must exit non-zero"
  let lock_before_db_line = (last-line $lock_before_db.stdout)
  assert ($lock_before_db_line | str contains "absent.lock") $"with an empty DB, a missing lock must still be the FAIL reason; got: ($lock_before_db_line)"
  assert (not ($lock_before_db_line | str replace $lock_absent "" | str contains "empty")) $"with a missing lock, the FAIL line must not name the empty DB; got: ($lock_before_db_line)"

  # default: no --ignore-file reads <repo>/.mix-audit-ignore, and no --lock-file
  # reads <repo>/mix.lock. Its IDs are absent from the fake DB, so each one prints INFO.
  assert equal $default_ignore.exit_code 0 $"the default ignore file must be read from the repo root; stdout: ($default_ignore.stdout) stderr: ($default_ignore.stderr)"
  for id in (live-skip-ids) {
    assert (has-line $default_ignore.stdout $"INFO audit:deps ($id) not in mix_audit DB") $"without --ignore-file, main must read <repo>/.mix-audit-ignore and report ($id)"
  }

  # blind control: a scanner that reports nothing on bandit 1.5.0 fails the gate.
  assert ($blind.exit_code != 0) "a blind positive control must exit non-zero"
  assert ((last-line $blind.stdout) | str starts-with $"FAIL audit:deps db=($db_date) positive control") "a blind positive control must end with FAIL audit:deps db=<date> positive control"

  # empty DB (git repo kept, no advisory files) fails.
  assert ($empty_db.exit_code != 0) "an empty advisory DB must exit non-zero"
  assert ((last-line $empty_db.stdout) | str starts-with "FAIL audit:deps") "an empty advisory DB must end with FAIL audit:deps"
  assert ((last-line $empty_db.stdout) | str contains "empty") "the empty-DB FAIL line must say empty"

  # missing DB directory fails.
  assert ($missing_db.exit_code != 0) "a missing advisory DB must exit non-zero"
  assert (has-line $missing_db.stdout "FAIL audit:deps") "a missing advisory DB must print FAIL audit:deps"
}

def main [] {
  seam-cases
  end-to-end-cases
  print "PASS test:deps-audit"
}
