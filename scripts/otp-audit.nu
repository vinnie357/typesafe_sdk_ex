#!/usr/bin/env nu
# otp-audit.nu: fail when the pinned or running Erlang/OTP is below the CVE floor (task audit:otp; issue #29).
#
# The hex and mix_audit gates cannot see OTP CVEs, so this gate checks two things. First, the erlang
# pinned in mise.toml must be a numeric version at or above the floor; latest, ref: and system pins
# fail closed. Second, the running OTP (the erl on PATH, read from its OTP_VERSION file) must be at or
# above the floor and match the pin, which catches mise.local.toml, .tool-versions, env overrides,
# a stale cache, or a system erl first on PATH. No network.
#
# Tests: test/test-otp-audit.nu (decision defs and main).

# Lowest OTP with fixes for CVE-2026-55953 (28.5.0.4), CVE-2026-89422 (28.5.0.7), and CVE-2026-105236,
# CVE-2026-94200 plus follow-up fixes for CVE-2026-42789 and CVE-2026-48856 (28.5.0.8).
# Raise it when a newer patch fixes a CVE; a floor above 28.5.0.8 also needs the pin and the
# 28.5.0.8 fixtures in test/test-otp-audit.nu moved.
export const otp_floor = "28.5.0.8"

const repo = (path self | path dirname | path dirname)

# Prints the full OTP version (for example 28.5.0.8). Never crashes, so erl writes no erl_crash.dump.
const otp_version_eval = 'case file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])) of {ok, B} -> io:put_chars(B); _ -> ok end, halt().'

def is-record [value]: nothing -> bool {
  $value | describe | str starts-with "record"
}

# Components of a dotted numeric version as ints; null for anything else (latest, ref:, system, a
# trailing `**` patched-build marker, a leading v, empty components, a non-string).
export def parse-version [text] {
  if ($text | describe) != "string" { return null }
  let trimmed = ($text | str trim)
  if not ($trimmed =~ '^\d+(\.\d+)*$') { return null }
  $trimmed | split row "." | each {|part| $part | into int }
}

# true when version a is below version b, comparing components as integers, padding with 0.
# Callers pass only parseable versions.
export def version-below [a: string, b: string]: nothing -> bool {
  let pa = (parse-version $a)
  let pb = (parse-version $b)
  let width = ([($pa | length) ($pb | length)] | math max)
  for i in 0..<$width {
    let x = ($pa | get -o $i | default 0)
    let y = ($pb | get -o $i | default 0)
    if $x < $y { return true }
    if $x > $y { return false }
  }
  false
}

# The erlang version pinned in mise.toml [tools]: a string, or a record's string `version`.
# null for a missing key, a list pin (ambiguous), any other type, or a non-record tools table.
export def pinned-erlang [tools] {
  if not (is-record $tools) { return null }
  let erlang = ($tools | get -o erlang)
  if ($erlang | describe) == "string" { return $erlang }
  if (is-record $erlang) {
    let version = ($erlang | get -o version)
    if ($version | describe) == "string" { return $version }
  }
  null
}

# {pass, reason}; the first failing check gives the reason.
export def otp-verdict [pin, running, floor: string] {
  let deny = {|reason| {pass: false, reason: $reason} }
  if $pin == null { return (do $deny "mise.toml pins no erlang version") }
  let pin_parts = (parse-version $pin)
  if $pin_parts == null { return (do $deny $"erlang pin '($pin)' is not a numeric version") }
  if (version-below $pin $floor) { return (do $deny $"pinned erlang ($pin) is below the ($floor) floor") }
  let run_parts = (parse-version $running)
  if $run_parts == null { return (do $deny $"cannot read the running OTP version \(got '($running)'\)") }
  let running_version = ($running | str trim)
  if (version-below $running_version $floor) {
    return (do $deny $"running OTP ($running_version) is below the ($floor) floor")
  }
  # The pin's integer components must be a prefix of the running components (equality for an exact pin).
  let width = ($pin_parts | length)
  if $width > ($run_parts | length) or ($run_parts | first $width) != $pin_parts {
    return (do $deny $"running OTP ($running_version) does not match the pinned erlang ($pin)")
  }
  {pass: true, reason: ""}
}

def fail [reason: string] {
  print $"FAIL audit:otp ($reason)"
  exit 1
}

def main [--mise-toml: path] {
  let toml_path = ($mise_toml | default ($repo | path join "mise.toml"))
  let tools = (try { open --raw $toml_path | from toml | get -o tools } catch { fail $"cannot read ($toml_path)" })
  let pin = (pinned-erlang $tools)
  # ERL_CRASH_DUMP_SECONDS=0: a crashing eval exits non-zero without writing erl_crash.dump into the cwd.
  let erl = (try {
    with-env {ERL_CRASH_DUMP_SECONDS: "0"} { ^erl -noshell -eval $otp_version_eval | complete }
  } catch { null })
  let running = if $erl == null or $erl.exit_code != 0 { null } else { $erl.stdout | str trim }
  let verdict = (otp-verdict $pin $running $otp_floor)
  if not $verdict.pass { fail $verdict.reason }
  print $"PASS audit:otp erlang=($pin) floor=($otp_floor)"
}
