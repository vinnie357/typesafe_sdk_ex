#!/usr/bin/env nu
# test-hex-audit-offline.nu — `audit:hex` must fail when Hex audits from cache.
#
# Shared audit script; keep in step with its upstream copy.
#
# With the Hex registry unreachable, `mix hex.audit` prints one
# `Failed to fetch record for <pkg> from registry (using cache instead)` line per
# package, then `No retired or security advisory packages found`, and exits 0.
# Advisory data comes from the registry fetch, so that run audits nothing.
#
# In real runs the cache-fallback lines go to STDERR: Hex prints them with
# Hex.Shell.error. The bad-mirror log merged both streams. The stderr cases are
# therefore the realistic ones; the stdout cases guard the other stream. Do not
# simplify the check to stdout only.
#
# An uncached failed fetch prints `Failed to fetch record for <pkg> from
# registry` with no `(using cache instead)` suffix, so the check matches both
# patterns.
#
# RED until scripts/hex-audit.nu takes the optional 4th argument: the 4-argument
# calls below fail to parse against the 3-parameter audit-verdict.
#
# Interface under test (scripts/hex-audit.nu):
#   export def audit-verdict [hex_version, exit_code: int, stdout: string, stderr: string = ""] -> record<pass: bool, reason: string>
#       Fails when stdout or stderr contains `Failed to fetch record` or
#       `using cache instead`, before the exit-code and stale checks. The reason
#       names the first such line. Three-argument calls (test/test-hex-audit.nu)
#       keep working.
#   main passes the audit's stderr as the 4th argument, and runs
#   `mix hex.audit` with HEX_OFFLINE forced to "false" (not only hidden), so a
#   caller HEX_OFFLINE or `mix hex.config offline true` cannot switch Hex to
#   its silent cache-only mode. Output markers: `PASS audit:hex` /
#   `FAIL audit:hex <reason>`.
#
# No network, no real `mix`: fixtures plus a fake `mix` on PATH. The shim tests
# HEX_OFFLINE's value and never prints it.

use std/assert
use ../scripts/hex-audit.nu *

const root = path self ..

# Verbatim from the Gate 1 bad-mirror run (HEX_MIRROR_URL=http://127.0.0.1:9).
const fallback_lines = "Failed to fetch record for dns_cluster from registry (using cache instead)
{:failed_connect, [{:to_address, {~c\"127.0.0.1\", 9}}, {:inet, [:inet], :econnrefused}]}
Failed to fetch record for cloak from registry (using cache instead)
{:failed_connect, [{:to_address, {~c\"127.0.0.1\", 9}}, {:inet, [:inet], :econnrefused}]}
Failed to fetch record for phoenix_live_reload from registry (using cache instead)
{:failed_connect, [{:to_address, {~c\"127.0.0.1\", 9}}, {:inet, [:inet], :econnrefused}]}
"

# An uncached failed fetch: no `(using cache instead)` suffix.
const uncached_lines = "Failed to fetch record for bandit from registry
{:failed_connect, [{:to_address, {~c\"127.0.0.1\", 9}}, {:inet, [:inet], :econnrefused}]}
"

const clean_stdout = "No retired or security advisory packages found\n"

const advisory_stdout = "Advisories:
  cowlib 2.21.0 - EEF-CVE-2026-43966 (MEDIUM)
    aka: CVE-2026-43966, GHSA-w4f7-4cxr-rv3c
    HTTP Response Splitting via Non-VCHAR Bytes in cow_http_struct_hd:escape_string/2
    https://osv.dev/vulnerability/EEF-CVE-2026-43966
"

def fixture-cases [] {
  let v = (audit-verdict "2.5.3" 0 $"($fallback_lines)($clean_stdout)" "")
  assert equal $v.pass false "cache-fallback lines on stdout with exit 0 must fail"
  assert ($v.reason | str contains "Failed to fetch record for dns_cluster") "the reason must name the first cache-fallback line"

  let v = (audit-verdict "2.5.3" 0 $clean_stdout $fallback_lines)
  assert equal $v.pass false "cache-fallback lines on stderr with exit 0 must fail"
  assert ($v.reason | str contains "Failed to fetch record for dns_cluster") "the reason must name the first cache-fallback line from stderr"

  let v = (audit-verdict "2.5.3" 0 $clean_stdout $uncached_lines)
  assert equal $v.pass false "an uncached failed fetch (no 'using cache instead' suffix) must fail"

  let v = (audit-verdict "2.5.3" 0 $clean_stdout "(using cache instead)\n")
  assert equal $v.pass false "a bare 'using cache instead' marker must fail"

  let v = (audit-verdict "2.5.3" 0 $clean_stdout "")
  assert equal $v.pass true "a clean run with empty stderr must pass"

  let v = (audit-verdict "2.5.3" 0 $clean_stdout)
  assert equal $v.pass true "a three-argument call on clean stdout must still pass"
}

def end-to-end-cases [] {
  let dir = (mktemp -d)
  $fallback_lines | save ($dir | path join "fallback.txt")
  $uncached_lines | save ($dir | path join "uncached.txt")
  $clean_stdout | save ($dir | path join "clean.txt")
  $advisory_stdout | save ($dir | path join "advisory.txt")

  # FAKE_HEX_AUDIT selects the hex.audit behaviour.
  # Offline model: Hex counts as ONLINE only when HEX_OFFLINE is exactly
  # "false". Any other value, and an UNSET variable, counts as offline: unset
  # models a persisted `mix hex.config offline true`, which only an explicit
  # HEX_OFFLINE=false in the environment overrides. Offline, the shim prints
  # the clean line and exits 0 (Hex's silent cache-only audit). Online, it
  # prints an advisory and exits 1. A script that forces HEX_OFFLINE to
  # "false" therefore FAILs on the advisory; a script that only hides the
  # variable passes the offline cases and fails this test.
  let shim = ($dir | path join "mix")
  [
    "#!/bin/sh"
    $"D='($dir)'"
    "case \"$1\" in"
    "  hex.info) printf 'Hex:    2.5.3\\nElixir: 1.19.6\\nOTP:    28.5.0.8\\n'; exit 0 ;;"
    "  hex.audit)"
    "    case \"$FAKE_HEX_AUDIT\" in"
    "      stdout_fallback) cat \"$D/fallback.txt\" \"$D/clean.txt\"; exit 0 ;;"
    "      stderr_fallback) cat \"$D/fallback.txt\" >&2; cat \"$D/clean.txt\"; exit 0 ;;"
    "      uncached) cat \"$D/uncached.txt\" >&2; cat \"$D/clean.txt\"; exit 0 ;;"
    "      offline)"
    "        if [ \"${HEX_OFFLINE-unset}\" = false ]; then"
    "          cat \"$D/advisory.txt\"; echo 'Found packages with security advisories' >&2; exit 1"
    "        fi"
    "        cat \"$D/clean.txt\"; exit 0 ;;"
    "      advisory) cat \"$D/advisory.txt\"; echo 'Found packages with security advisories' >&2; exit 1 ;;"
    "    esac"
    "    exit 99 ;;"
    "  *) echo \"unexpected mix call: $1\" >&2; exit 99 ;;"
    "esac"
  ] | str join "\n" | save $shim
  ^chmod +x $shim

  let script = ($root | path join "scripts" "hex-audit.nu")
  let path = ($env.PATH | prepend $dir)
  let on_stdout = (do { with-env {PATH: $path, FAKE_HEX_AUDIT: "stdout_fallback"} { ^nu -n $script } } | complete)
  let on_stderr = (do { with-env {PATH: $path, FAKE_HEX_AUDIT: "stderr_fallback"} { ^nu -n $script } } | complete)
  let uncached = (do { with-env {PATH: $path, FAKE_HEX_AUDIT: "uncached"} { ^nu -n $script } } | complete)
  let offline_unset = (do { hide-env -i HEX_OFFLINE; with-env {PATH: $path, FAKE_HEX_AUDIT: "offline"} { ^nu -n $script } } | complete)
  let offline_1 = (do { with-env {PATH: $path, FAKE_HEX_AUDIT: "offline", HEX_OFFLINE: "1"} { ^nu -n $script } } | complete)
  let offline_true = (do { with-env {PATH: $path, FAKE_HEX_AUDIT: "offline", HEX_OFFLINE: "true"} { ^nu -n $script } } | complete)
  let control = (do { with-env {PATH: $path, FAKE_HEX_AUDIT: "advisory"} { ^nu -n $script } } | complete)
  rm -rf $dir

  assert ($on_stdout.exit_code != 0) $"cache-fallback lines on stdout must fail the gate; stdout: ($on_stdout.stdout)"
  assert ($on_stdout.stdout | str contains "FAIL audit:hex") "cache-fallback lines on stdout must print FAIL audit:hex"

  assert ($on_stderr.exit_code != 0) $"cache-fallback lines on stderr must fail the gate; stdout: ($on_stderr.stdout)"
  assert ($on_stderr.stdout | str contains "FAIL audit:hex") "cache-fallback lines on stderr must print FAIL audit:hex"

  assert ($uncached.exit_code != 0) $"an uncached failed fetch must fail the gate; stdout: ($uncached.stdout)"
  assert ($uncached.stdout | str contains "FAIL audit:hex") "an uncached failed fetch must print FAIL audit:hex"

  # Caller leaves HEX_OFFLINE unset (persisted offline config): only a script
  # that FORCES HEX_OFFLINE=false reaches the online branch.
  assert ($offline_unset.exit_code != 0) $"with HEX_OFFLINE unset the script must force it to false; stdout: ($offline_unset.stdout)"
  assert ($offline_unset.stdout | str contains "FAIL audit:hex") "with HEX_OFFLINE unset the script must still print FAIL audit:hex on an advisory"

  assert ($offline_1.exit_code != 0) $"caller HEX_OFFLINE=1 must not reach mix hex.audit; stdout: ($offline_1.stdout)"
  assert ($offline_1.stdout | str contains "FAIL audit:hex") "caller HEX_OFFLINE=1 must still print FAIL audit:hex on an advisory"

  assert ($offline_true.exit_code != 0) $"caller HEX_OFFLINE=true must not reach mix hex.audit; stdout: ($offline_true.stdout)"
  assert ($offline_true.stdout | str contains "FAIL audit:hex") "caller HEX_OFFLINE=true must still print FAIL audit:hex on an advisory"

  # Control: proves the shim's advisory path is sound.
  assert ($control.exit_code != 0) "an advisory must fail the gate"
  assert ($control.stdout | lines | any {|l| ($l | str starts-with "FAIL audit:hex") and ($l | str contains "EEF-CVE-2026-43966") }) "the FAIL audit:hex line must name the advisory"
}

def main [] {
  fixture-cases
  end-to-end-cases
  print "PASS test:hex-audit-offline"
}
