#!/usr/bin/env nu
# test-hex-audit.nu — fixture tests for the decision defs in scripts/hex-audit.nu.
#
# scripts/hex-audit.nu does not exist yet. This whole file is RED (fails to
# parse: module not found) until the implementer adds it. No network, no real
# `mix` call: the decision cases use fixture strings, and the end-to-end cases
# run the script against a fake `mix` shim on PATH.
#
# Interface under test (the script's `main` gathers the values, runs the
# commands and calls these):
#   export def parse-hex-version [info: string] -> string or null
#       Version from the `Hex:    2.5.3` line of `mix hex.info` stdout; null when absent.
#   export def needs-hex-install [hex_version] -> bool
#       true when hex_version is null or below the 2.5.3 floor.
#   export def audit-verdict [hex_version, exit_code: int, stdout: string, stderr: string = ""] -> record<pass: bool, reason: string>
#       Decision for one `mix hex.audit` run. When the exit code is non-zero
#       and stdout also has an `and can be removed` line, the reason is
#       `<first finding>; stale allow-list entry: <line>`.
#
# Interface notes:
# - parse-hex-version returns null for missing Hex, so its return type cannot
#   be annotated `string`. The first parameter of needs-hex-install and
#   audit-verdict receives null, so leave it untyped (or `any`).
# - The optional "count Ignored advisories: entries against mix.exs" check
#   cannot live in audit-verdict: it has no mix.exs input, and reading the
#   file there breaks the fixture cases. Put it in `main` or skip it.
#
# `main` contract (end-to-end cases at the bottom; task `audit:hex`):
# - runs `mix hex.info`, then `mix hex.audit` as its own standalone `mix`
#   process (never `mix do ...`), with HEX_IGNORE_ADVISORIES and
#   HEX_IGNORE_RETIREMENTS hidden from it (`hide-env -i ...`);
# - prints the captured `mix hex.audit` stdout (no silent pipe);
# - prints one `PASS audit:hex` or `FAIL audit:hex <reason>` line;
# - exits non-zero on FAIL.
#
# Hex facts behind the cases: advisory checks exist since Hex 2.5.0,
# `ignore_advisories` since 2.5.1, and the floor is 2.5.3. Hex 2.3.2 prints
# "No retired packages found" and exits 0 on a vulnerable lock (false green).
# Stale allow-list entries exit 0 and print a yellow warning ending in
# "and can be removed" on stdout, with the ANSI bytes present when piped.

use std/assert
use ../scripts/hex-audit.nu *

const root = path self ..

const advisory_stdout = "Advisories:
  cowlib 2.21.0 - EEF-CVE-2026-43966 (MEDIUM)
    aka: CVE-2026-43966, GHSA-w4f7-4cxr-rv3c
    HTTP Response Splitting via Non-VCHAR Bytes in cow_http_struct_hd:escape_string/2
    https://osv.dev/vulnerability/EEF-CVE-2026-43966
"

const ignored_stdout = "No retired packages found
Ignored advisories:
  cowlib 2.21.0 - EEF-CVE-2026-43966 (MEDIUM)
    aka: CVE-2026-43966, GHSA-w4f7-4cxr-rv3c
    HTTP Response Splitting via Non-VCHAR Bytes in cow_http_struct_hd:escape_string/2
    https://osv.dev/vulnerability/EEF-CVE-2026-43966
"

def stale_advisory_stdout [] {
  $"No retired packages found\n(ansi -e '33m')ignore_advisories entry \"CVE-2099-00001\" \(set in mix.exs\) does not match any advisory for the locked dependencies and can be removed(ansi -e '0m')\n"
}

def stale_retirement_stdout [] {
  $"No retired packages found\n(ansi -e '33m')ignore_retirements entry \"oldpkg\" \(set in mix.exs\) does not match any retired locked dependency and can be removed(ansi -e '0m')\n"
}

def main [] {
  # -------- fixtures carry the real ANSI bytes --------
  assert ((stale_advisory_stdout) | str contains "\e[33mignore_advisories entry \"CVE-2099-00001\" (set in mix.exs) does not match any advisory for the locked dependencies and can be removed\e[0m") "fixture must carry the verified Hex 2.5.3 stale line with ESC[33m ... ESC[0m"
  assert ((stale_retirement_stdout) | str contains "\e[33m") "retirement fixture must carry the ESC[33m prefix"

  # -------- parse-hex-version --------
  let info = "Hex:    2.5.3\nElixir: 1.19.5\nOTP:    28.4.2\n\nBuilt with: Elixir 1.19.5 and OTP 28.4.1\n"
  assert equal (parse-hex-version $info) "2.5.3" "parse-hex-version must read the Hex: line, not the Elixir/OTP/Built with lines"
  assert equal (parse-hex-version "Hex:    2.6.0\nElixir: 1.19.6\n") "2.6.0" "parse-hex-version must read 2.6.0"
  assert equal (parse-hex-version "Hex:    2.10.1\n") "2.10.1" "parse-hex-version must keep multi-digit components"
  assert equal (parse-hex-version "") null "parse-hex-version must return null for empty output (Hex missing)"
  assert equal (parse-hex-version "** (Mix) The task \"hex.info\" could not be found\n") null "parse-hex-version must return null when Hex is not installed"

  # -------- needs-hex-install --------
  assert equal (needs-hex-install null) true "missing Hex must install"
  assert equal (needs-hex-install "2.3.2") true "Hex 2.3.2 (retirement-only audit) must install"
  assert equal (needs-hex-install "2.5.0") true "Hex 2.5.0 (no ignore_advisories) is below the 2.5.3 floor and must install"
  assert equal (needs-hex-install "2.5.2") true "Hex 2.5.2 is below the 2.5.3 floor and must install"
  assert equal (needs-hex-install "2.5.3") false "Hex 2.5.3 is the floor and must not reinstall"
  assert equal (needs-hex-install "2.6.0") false "Hex 2.6.0 is above the floor and must not be downgraded"
  assert equal (needs-hex-install "2.10.0") false "Hex 2.10.0 must compare numerically, not as a string"
  assert equal (needs-hex-install "3.0.0") false "Hex 3.0.0 is above the floor"

  # -------- audit-verdict: findings --------
  let v = (audit-verdict "2.5.3" 1 $advisory_stdout)
  assert equal $v.pass false "exit 1 with an advisory must fail"
  assert (($v.reason | str trim) != "") "a failing verdict must carry a reason"

  let v = (audit-verdict "2.5.3" 1 "")
  assert equal $v.pass false "exit 1 with empty stdout must still fail"

  let v = (audit-verdict "2.5.3" 2 "")
  assert equal $v.pass false "any non-zero exit must fail"

  # -------- audit-verdict: an advisory and a stale entry in one run --------
  # Hex exits 1 on the advisory and also prints the stale warning. The reason
  # must name both, so one CI run shows both fixes the operator needs.
  let v = (audit-verdict "2.5.3" 1 $"($advisory_stdout)(stale_advisory_stdout)")
  assert equal $v.pass false "exit 1 with an advisory and a stale entry must fail"
  assert ($v.reason | str contains "EEF-CVE-2026-43966") $"the reason must name the first finding beside a stale entry; got: ($v.reason)"
  assert ($v.reason | str contains "stale allow-list entry") $"the reason must say `stale allow-list entry` beside a finding; got: ($v.reason)"
  assert ($v.reason | str contains "CVE-2099-00001") $"the reason must name the stale entry beside a finding; got: ($v.reason)"

  # -------- audit-verdict: allow-listed findings --------
  let v = (audit-verdict "2.5.3" 0 $ignored_stdout)
  assert equal $v.pass true "exit 0 with only an Ignored advisories: section must pass"

  # -------- audit-verdict: stale allow-list entries --------
  let v = (audit-verdict "2.5.3" 0 (stale_advisory_stdout))
  assert equal $v.pass false "exit 0 with a stale ignore_advisories warning must fail"
  assert ($v.reason | str contains "CVE-2099-00001") "stale-advisory failure reason must name the stale entry"

  let v = (audit-verdict "2.5.3" 0 (stale_retirement_stdout))
  assert equal $v.pass false "exit 0 with a stale ignore_retirements warning must fail"
  assert ($v.reason | str contains "oldpkg") "stale-retirement failure reason must name the stale entry"

  let v = (audit-verdict "2.5.3" 0 $"($ignored_stdout)(stale_advisory_stdout)")
  assert equal $v.pass false "a stale warning must fail even beside a valid Ignored advisories: section"

  # -------- audit-verdict: Hex version floor --------
  let v = (audit-verdict "2.3.2" 0 "No retired packages found\n")
  assert equal $v.pass false "Hex 2.3.2 exit 0 is the false green and must fail"
  assert ($v.reason | str contains "2.5.3") "floor failure reason must name the 2.5.3 floor"

  let v = (audit-verdict "2.5.0" 0 "No retired packages found\n")
  assert equal $v.pass false "Hex 2.5.0 is below the floor and must fail"

  let v = (audit-verdict null 0 "No retired packages found\n")
  assert equal $v.pass false "missing Hex version must fail"

  # -------- audit-verdict: clean --------
  let v = (audit-verdict "2.5.3" 0 "No retired packages found\n")
  assert equal $v.pass true "Hex 2.5.3 clean run must pass"

  let v = (audit-verdict "2.6.0" 0 "No retired packages found\n")
  assert equal $v.pass true "Hex 2.6.0 clean run must pass"

  let v = (audit-verdict "2.10.0" 0 $ignored_stdout)
  assert equal $v.pass true "Hex 2.10.0 must compare numerically and pass"

  # -------- main end to end: fake `mix` on PATH --------
  # The shim's hex.audit exits 0 when either HEX_IGNORE_* override reaches it,
  # as Hex does when the override silences findings. A script that does not
  # hide those variables therefore prints PASS and fails these cases.
  let dir = (mktemp -d)
  let shim = ($dir | path join "mix")
  let advisory_file = ($dir | path join "advisory.txt")
  let both_file = ($dir | path join "both.txt")
  $advisory_stdout | save $advisory_file
  $"($advisory_stdout)(stale_advisory_stdout)" | save $both_file
  [
    "#!/bin/sh"
    "case \"$1\" in"
    "  hex.info) printf 'Hex:    2.5.3\\nElixir: 1.19.6\\nOTP:    28.5.0.8\\n'; exit 0 ;;"
    "  hex.audit)"
    "    if [ -n \"$HEX_IGNORE_ADVISORIES\" ] || [ -n \"$HEX_IGNORE_RETIREMENTS\" ] || [ \"$FAKE_MIX_AUDIT\" = clean ]; then"
    "      printf 'No retired packages found\\n'; exit 0"
    "    fi"
    $"    if [ \"$FAKE_MIX_AUDIT\" = both ]; then cat '($both_file)'; echo 'Found packages with security advisories' >&2; exit 1; fi"
    $"    cat '($advisory_file)'; echo 'Found packages with security advisories' >&2; exit 1 ;;"
    "  *) echo \"unexpected mix call: $*\" >&2; exit 99 ;;"
    "esac"
  ] | str join "\n" | save $shim
  ^chmod +x $shim

  let script = ($root | path join "scripts" "hex-audit.nu")
  let path = ($env.PATH | prepend $dir)
  let with_adv = (do { with-env {PATH: $path, HEX_IGNORE_ADVISORIES: "1"} { ^nu $script } } | complete)
  let with_ret = (do { with-env {PATH: $path, HEX_IGNORE_RETIREMENTS: "1"} { ^nu $script } } | complete)
  let clean = (do { with-env {PATH: $path, FAKE_MIX_AUDIT: "clean"} { ^nu $script } } | complete)
  let both = (do { with-env {PATH: $path, FAKE_MIX_AUDIT: "both"} { ^nu $script } } | complete)
  rm -rf $dir

  assert ($with_adv.exit_code != 0) $"HEX_IGNORE_ADVISORIES in the caller env must not silence the audit; exit ($with_adv.exit_code), stdout: ($with_adv.stdout)"
  assert ($with_adv.stdout | str contains "FAIL audit:hex") "an advisory must print FAIL audit:hex even with HEX_IGNORE_ADVISORIES set"
  assert ($with_adv.stdout | str contains "EEF-CVE-2026-43966") "main must print the captured mix hex.audit stdout"

  assert ($with_ret.exit_code != 0) $"HEX_IGNORE_RETIREMENTS in the caller env must not silence the audit; exit ($with_ret.exit_code), stdout: ($with_ret.stdout)"
  assert ($with_ret.stdout | str contains "FAIL audit:hex") "an advisory must print FAIL audit:hex even with HEX_IGNORE_RETIREMENTS set"

  assert equal $clean.exit_code 0 $"a clean audit must exit 0; stderr: ($clean.stderr)"
  assert ($clean.stdout | str contains "PASS audit:hex") "a clean audit must print PASS audit:hex"
  assert (not ($clean.stdout | str contains "FAIL audit:hex")) "a clean audit must not print FAIL audit:hex"

  # End to end: the one FAIL line names the finding and the stale entry.
  assert ($both.exit_code != 0) $"an advisory beside a stale entry must exit non-zero; stdout: ($both.stdout)"
  let both_fail = ($both.stdout | lines | where {|l| $l | str starts-with "FAIL audit:hex" })
  assert equal ($both_fail | length) 1 $"an advisory beside a stale entry must print one FAIL audit:hex line; stdout: ($both.stdout)"
  assert ($both_fail.0 | str contains "EEF-CVE-2026-43966") $"the FAIL line must name the finding; got: ($both_fail.0)"
  assert ($both_fail.0 | str contains "stale allow-list entry") $"the FAIL line must name the stale entry; got: ($both_fail.0)"
  assert ($both_fail.0 | str contains "CVE-2099-00001") $"the FAIL line must name the stale ID; got: ($both_fail.0)"

  print "PASS test:hex-audit"
}
