#!/usr/bin/env nu
# hex-audit.nu: gate `mix hex.audit` on Hex >= 2.5.3 (task audit:hex).
#
# Fails on any advisory or retirement not allow-listed in mix.exs (`hex: [ignore_advisories: ...]`),
# on a stale allow-list entry, which Hex only warns about, and on a registry cache fallback, which
# Hex reports with exit 0. A finding beside a stale entry names both in one FAIL line.
# Advisory checks need Hex >= 2.5.0; older Hex prints "No retired packages found" and exits 0
# on a vulnerable lock, so the floor is enforced here. Needs network.
#
# Tests: test/test-hex-audit.nu (decision defs and main).

const hex_floor = "2.5.3"
const cache_patterns = ["Failed to fetch record" "using cache instead"]

def version-parts [version: string]: nothing -> list<int> {
  $version | split row "." | each {|part| $part | into int }
}

# true when version a is below version b, comparing components as integers.
def version-below [a: string, b: string]: nothing -> bool {
  let pa = (version-parts $a)
  let pb = (version-parts $b)
  let width = ([($pa | length) ($pb | length)] | math max)
  for i in 0..<$width {
    let x = ($pa | get -o $i | default 0)
    let y = ($pb | get -o $i | default 0)
    if $x < $y { return true }
    if $x > $y { return false }
  }
  false
}

# Version from the `Hex:    2.5.3` line of `mix hex.info` stdout; null when absent.
export def parse-hex-version [info: string] {
  let hits = ($info | lines | parse --regex '^Hex:\s+(?<v>\d+(?:\.\d+)*)\s*$')
  if ($hits | is-empty) { null } else { $hits.0.v }
}

# true when Hex is missing or below the floor.
export def needs-hex-install [hex_version]: nothing -> bool {
  ($hex_version | is-empty) or (version-below $hex_version $hex_floor)
}

# First finding line in `mix hex.audit` stdout, after the Advisories or Retired packages header.
def first-finding [stdout: string] {
  let lines = ($stdout | ansi strip | lines)
  let headers = ($lines | enumerate | where {|l| $l.item =~ '^(Advisories|Retired packages):' })
  if ($headers | is-empty) { return null }
  let rest = ($lines | skip ($headers.0.index + 1) | where {|l| ($l | str trim) != "" })
  if ($rest | is-empty) { null } else { $rest.0 | str trim }
}

# Decision for one `mix hex.audit` run. The first failing check gives the reason.
export def audit-verdict [hex_version, exit_code: int, stdout: string, stderr: string = ""]: nothing -> record<pass: bool, reason: string> {
  let fallback = ([$stdout $stderr] | each {|s| $s | ansi strip | lines } | flatten
    | where {|l| $cache_patterns | any {|p| $l | str contains $p } })
  if ($fallback | is-not-empty) {
    return {pass: false, reason: $"registry unreachable: ($fallback.0 | str trim)"}
  }
  if ($hex_version | is-empty) {
    return {pass: false, reason: $"Hex not found; mix hex.audit needs Hex >= ($hex_floor)"}
  }
  if (version-below $hex_version $hex_floor) {
    return {pass: false, reason: $"Hex ($hex_version) is below the ($hex_floor) floor; older Hex does not check advisories"}
  }
  let stale = ($stdout | ansi strip | lines | where {|l| $l | str contains "and can be removed" })
  if $exit_code != 0 {
    let finding = (first-finding $stdout)
    let reason = if $finding == null { $"mix hex.audit exited ($exit_code)" } else { $finding }
    if ($stale | is-empty) { return {pass: false, reason: $reason} }
    return {pass: false, reason: $"($reason); stale allow-list entry: ($stale.0 | str trim)"}
  }
  if ($stale | is-not-empty) {
    return {pass: false, reason: $"stale allow-list entry: ($stale.0 | str trim)"}
  }
  {pass: true, reason: ""}
}

def fail [reason: string] {
  print $"FAIL audit:hex ($reason)"
  exit 1
}

def main [] {
  mut version = (parse-hex-version (^mix hex.info | complete).stdout)
  if (needs-hex-install $version) {
    print $"Hex ($version | default 'missing') is below ($hex_floor); installing Hex ($hex_floor)"
    let install = (^mix local.hex $hex_floor --force | complete)
    print $install.stdout
    if $install.exit_code != 0 {
      print --stderr $install.stderr
      fail $"mix local.hex ($hex_floor) exited ($install.exit_code)"
    }
    $version = (parse-hex-version (^mix hex.info | complete).stdout)
    if (needs-hex-install $version) {
      fail $"Hex ($version | default 'missing') is still below the ($hex_floor) floor after install"
    }
  }

  # Standalone mix process. HEX_IGNORE_* would silence findings outside mix.exs, and offline mode
  # (env or a persisted `mix hex.config offline true`) audits the cached registry.
  let audit = (do {
    hide-env -i HEX_IGNORE_ADVISORIES HEX_IGNORE_RETIREMENTS
    with-env {HEX_OFFLINE: "false"} { ^mix hex.audit | complete }
  })
  print $audit.stdout
  if ($audit.stderr | str trim) != "" { print --stderr $audit.stderr }

  let verdict = (audit-verdict $version $audit.exit_code $audit.stdout $audit.stderr)
  if not $verdict.pass { fail $verdict.reason }
  print "PASS audit:hex"
}
