#!/usr/bin/env nu
# test-otp-audit.nu — fixture tests for scripts/otp-audit.nu (issue #29).
#
# scripts/otp-audit.nu does not exist yet. This whole file is RED (fails to
# parse: module not found) until the implementer adds it. No network, no real
# `erl` call: the decision cases use fixture values, and the end-to-end cases
# run the script against fixture mise.toml files in a temp dir and a fake
# `erl` shim on PATH.
#
# Interface under test (the script's `main` gathers the values and calls these):
#   export const otp_floor: string
#       Lowest OTP with the CVE-2026-55953 (28.5.0.4) and CVE-2026-89422
#       (28.5.0.7) fixes. The test only asserts it is never below 28.5.0.7, so
#       a raise needs no test edit.
#   export def parse-version [text] -> list<int> or null
#       Trimmed `^\d+(\.\d+)*$` as ints; null for anything else, including a
#       non-string.
#   export def version-below [a: string, b: string] -> bool
#       Integer component compare, the shorter list padded with 0.
#   export def pinned-erlang [tools] -> string or null
#       mise.toml [tools] `erlang` as a string, or `erlang.version` from a
#       record; null for a missing key, a list, a non-string, or a non-record
#       `tools`.
#   export def otp-verdict [pin, running, floor: string] -> record<pass: bool, reason: string>
#       First failing check, in order: no pin; pin not numeric; pin below the
#       floor; running unreadable; running below the floor; pin components not
#       an integer prefix of the running components ("does not match").
#
# main contract (`nu scripts/otp-audit.nu [--mise-toml <path>]`):
# - reads <repo>/mise.toml by default (repo from the script path, not cwd);
# - runs `erl -noshell -eval <eval>` for the running OTP version;
# - prints exactly one `PASS audit:otp ...` or `FAIL audit:otp <reason>` line;
# - exits non-zero on FAIL, and never dies with a bare nu error (missing or
#   unparseable mise.toml, non-record [tools], missing erl all print FAIL).

use std/assert
use ../scripts/otp-audit.nu *

const root = path self ..

def fail-lines [out: string] {
  $out | lines | where {|l| $l | str starts-with "FAIL audit:otp" }
}

def pass-lines [out: string] {
  $out | lines | where {|l| $l | str starts-with "PASS audit:otp" }
}

# One FAIL line, no PASS line, non-zero exit; returns the FAIL line.
def assert-fails [r: record, label: string] {
  assert ($r.exit_code != 0) $"($label): must exit non-zero; stdout: ($r.stdout) stderr: ($r.stderr)"
  let f = (fail-lines $r.stdout)
  assert equal ($f | length) 1 $"($label): must print exactly one FAIL audit:otp line; stdout: ($r.stdout) stderr: ($r.stderr)"
  assert equal (pass-lines $r.stdout | length) 0 $"($label): must not print PASS audit:otp; stdout: ($r.stdout)"
  $f.0
}

def assert-passes [r: record, label: string] {
  assert equal $r.exit_code 0 $"($label): must exit 0; stdout: ($r.stdout) stderr: ($r.stderr)"
  assert equal (pass-lines $r.stdout | length) 1 $"($label): must print exactly one PASS audit:otp line; stdout: ($r.stdout)"
  assert equal (fail-lines $r.stdout | length) 0 $"($label): must not print FAIL audit:otp; stdout: ($r.stdout)"
}

def main [] {
  # -------- A. floor guard --------
  assert ((parse-version $otp_floor) != null) $"otp_floor must be a numeric version; got: ($otp_floor)"
  assert (not (version-below $otp_floor "28.5.0.7")) $"otp_floor must never drop below 28.5.0.7 \(CVE-2026-89422 fix\); got: ($otp_floor)"

  # -------- B. parse-version --------
  assert equal (parse-version "28.5.0.8") [28 5 0 8] "parse-version must split 28.5.0.8 into ints"
  assert equal (parse-version "28.5") [28 5] "parse-version must accept a fuzzy 28.5"
  assert equal (parse-version "28.5.0.10") [28 5 0 10] "parse-version must keep multi-digit components"
  assert equal (parse-version " 28.5.0.8\n") [28 5 0 8] "parse-version must trim whitespace"
  for bad in ["latest" "ref:OTP-28.5.0.8" "system" "28.5.0.8**" "v28.5" "28..5" ""] {
    assert equal (parse-version $bad) null $"parse-version must return null for '($bad)'"
  }
  assert equal (parse-version null) null "parse-version must return null for null"
  assert equal (parse-version 28) null "parse-version must return null for a non-string (int 28)"

  # -------- C. version-below --------
  assert equal (version-below "28.5.0.7" "28.5.0.10") true "28.5.0.7 < 28.5.0.10 (numeric, not string order)"
  assert equal (version-below "28.5.0.10" "28.5.0.7") false "28.5.0.10 is not below 28.5.0.7 (numeric, not string order)"
  assert equal (version-below "28.5" "28.5.0.7") true "28.5 pads to 28.5.0.0 and is below 28.5.0.7"
  assert equal (version-below "28.5.0.7" "28.5.0.7") false "equal versions are not below"
  assert equal (version-below "28.5.0.7.0" "28.5.0.7") false "28.5.0.7.0 equals 28.5.0.7 after padding"
  assert equal (version-below "28.4.2" "28.5.0.7") true "28.4.2 is below 28.5.0.7"
  assert equal (version-below "29" "28.5.0.7") false "29 is above 28.5.0.7"
  assert equal (version-below "28.5.0.6" "28.5.0.7") true "28.5.0.6 is below 28.5.0.7"

  # -------- D. pinned-erlang --------
  assert equal (pinned-erlang {erlang: "28.5.0.8"}) "28.5.0.8" "string erlang pin"
  assert equal (pinned-erlang {erlang: {version: "28.5.0.8"}}) "28.5.0.8" "record erlang pin reads .version"
  assert equal (pinned-erlang {}) null "no erlang key returns null"
  assert equal (pinned-erlang {elixir: "1.19.6-otp-28"}) null "elixir-only tools returns null"
  assert equal (pinned-erlang {erlang: ["28.5.0.8" "27.3"]}) null "a list pin is ambiguous and returns null"
  assert equal (pinned-erlang {erlang: 28}) null "an int pin returns null"
  assert equal (pinned-erlang "x") null "a non-record tools returns null, not a nu error"

  # -------- E. otp-verdict (floor passed explicitly) --------
  let floor = "28.5.0.7"
  for ok in [["28.5.0.8" "28.5.0.8"] ["28.5.0.7" "28.5.0.7"] ["28.5.0.10" "28.5.0.10"] ["29" "29.0.1"]] {
    let v = (otp-verdict $ok.0 $ok.1 $floor)
    assert equal $v.pass true $"pin ($ok.0) running ($ok.1) must pass; reason: ($v.reason)"
  }

  let fails = [
    {pin: "28.4.2", running: "28.4.2", has: ["28.4.2" "28.5.0.7"], why: "today's pin, the regression case"}
    {pin: "28.5.0.6", running: "28.5.0.6", has: ["28.5.0.6"], why: "pin one patch below the floor"}
    {pin: "28.5", running: "28.5.0.8", has: ["28.5"], why: "fuzzy pin below the floor"}
    {pin: null, running: "28.5.0.8", has: ["pins no erlang"], why: "no pin"}
    {pin: "latest", running: "28.5.0.8", has: ["latest"], why: "latest pin"}
    {pin: "ref:OTP-28.5.0.8", running: "28.5.0.8", has: ["ref:OTP-28.5.0.8"], why: "ref pin"}
    {pin: "28.5.0.8", running: null, has: ["running OTP"], why: "running unreadable (null)"}
    {pin: "28.5.0.8", running: "", has: ["running OTP"], why: "running unreadable (empty)"}
    {pin: "28.5.0.8", running: "28.5.0.6", has: ["below"], why: "running below the floor"}
    {pin: "28.5.0.8", running: "28.5.0.9", has: ["does not match"], why: "running drift above the floor"}
    {pin: "28.5.0.8", running: "28.5.0.80", has: ["does not match"], why: "integer components, not a string prefix"}
  ]
  for c in $fails {
    let v = (otp-verdict $c.pin $c.running $floor)
    assert equal $v.pass false $"($c.why): pin ($c.pin) running ($c.running) must fail"
    assert (($v.reason | str trim) != "") $"($c.why): a failing verdict must carry a reason"
    for s in $c.has {
      assert ($v.reason | str contains $s) $"($c.why): reason must contain '($s)'; got: ($v.reason)"
    }
  }

  # -------- F. main end to end: fixture mise.toml + fake `erl` on PATH --------
  let dir = (mktemp -d)
  let bin = ($dir | path join "bin")
  let empty_bin = ($dir | path join "empty-bin")
  let work = ($dir | path join "work")
  mkdir $bin $empty_bin $work
  let shim = ($bin | path join "erl")
  [
    "#!/bin/sh"
    "if [ \"$FAKE_ERL\" = fail ]; then echo 'fake erl failure' >&2; exit 1; fi"
    "if [ \"$1\" = -noshell ] && [ \"$2\" = -eval ]; then printf '%s' \"$FAKE_OTP_VERSION\"; exit 0; fi"
    "echo \"unexpected erl call: $*\" >&2"
    "exit 99"
  ] | str join "\n" | save $shim
  ^chmod +x $shim

  let fixture = {|name: string, text: string|
    let p = ($dir | path join $name)
    $text | save $p
    $p
  }
  let pin_ok = (do $fixture "ok.toml" "[tools]\nerlang = \"28.5.0.8\"\nelixir = \"1.19.6-otp-28\"\n")
  let pin_old = (do $fixture "old.toml" "[tools]\nerlang = \"28.4.2\"\nelixir = \"1.19.5-otp-28\"\n")
  let pin_latest = (do $fixture "latest.toml" "[tools]\nerlang = \"latest\"\n")
  let pin_none = (do $fixture "none.toml" "[tools]\nelixir = \"1.19.6-otp-28\"\n")
  let pin_broken = (do $fixture "broken.toml" "[tools\nerlang = ")
  let pin_record = (do $fixture "record.toml" "[tools]\nerlang = { version = \"28.5.0.8\" }\n")
  let tools_str = (do $fixture "tools-str.toml" "tools = \"x\"\n")
  let pin_absent = ($dir | path join "absent.toml")

  let script = ($root | path join "scripts" "otp-audit.nu")
  let path = ($env.PATH | prepend $bin)
  # toml == "" runs without --mise-toml, so main uses its <repo>/mise.toml default.
  # cwd is the temp work dir, so a cwd-relative default fails the default case.
  let run = {|toml: string, fake: record|
    let flags = if $toml == "" { [] } else { ["--mise-toml" $toml] }
    do {
      hide-env -i FAKE_ERL FAKE_OTP_VERSION
      cd $work
      with-env ({PATH: $path} | merge $fake) { ^nu -n $script ...$flags }
    } | complete
  }

  let real_pin = (open ($root | path join "mise.toml") | get -o tools.erlang)

  let f1 = (do $run $pin_ok {FAKE_OTP_VERSION: "28.5.0.8"})
  let f2 = (do $run $pin_old {FAKE_OTP_VERSION: "28.4.2"})
  let f3 = (do $run $pin_latest {FAKE_OTP_VERSION: "28.5.0.8"})
  let f4 = (do $run $pin_none {FAKE_OTP_VERSION: "28.5.0.8"})
  let f5 = (do $run $pin_broken {FAKE_OTP_VERSION: "28.5.0.8"})
  let f6 = (do $run $pin_absent {FAKE_OTP_VERSION: "28.5.0.8"})
  let f7a = (do $run $pin_ok {FAKE_ERL: "fail", FAKE_OTP_VERSION: "28.5.0.8"})
  let f7b = (do $run $pin_ok {FAKE_OTP_VERSION: ""})
  let f8 = (do {
    hide-env -i FAKE_ERL FAKE_OTP_VERSION
    cd $work
    with-env {PATH: [$empty_bin]} { ^$nu.current-exe -n $script --mise-toml $pin_ok }
  } | complete)
  let f9 = (do $run $pin_ok {FAKE_OTP_VERSION: "28.5.0.9"})
  let f10 = (do $run $pin_record {FAKE_OTP_VERSION: "28.5.0.8"})
  let f11 = (do $run "" {FAKE_OTP_VERSION: ($real_pin | default "" | into string)})
  let f13 = (do $run $tools_str {FAKE_OTP_VERSION: "28.5.0.8"})
  rm -rf $dir

  # F1: matching pin and running OTP pass.
  assert-passes $f1 "F1 pin 28.5.0.8, erl 28.5.0.8"

  # F2: today's pin fails, naming the pin and the floor.
  let l = (assert-fails $f2 "F2 pin 28.4.2")
  assert ($l | str contains "28.4.2") $"F2: the FAIL line must name the pin 28.4.2; got: ($l)"
  assert ($l | str contains $otp_floor) $"F2: the FAIL line must name the floor ($otp_floor); got: ($l)"

  # F3: latest fails closed.
  let l = (assert-fails $f3 "F3 pin latest")
  assert ($l | str contains "latest") $"F3: the FAIL line must name the latest pin; got: ($l)"

  # F4: no erlang pin.
  let l = (assert-fails $f4 "F4 no erlang in [tools]")
  assert ($l | str contains "pins no erlang") $"F4: the FAIL line must say pins no erlang; got: ($l)"

  # F5/F6: unreadable mise.toml prints a FAIL line, not a bare nu error.
  assert-fails $f5 "F5 unparseable mise.toml" | ignore
  assert-fails $f6 "F6 missing mise.toml" | ignore

  # F7: erl failing or printing nothing.
  let l = (assert-fails $f7a "F7 erl exits 1")
  assert ($l | str contains "running OTP") $"F7: the FAIL line must name running OTP; got: ($l)"
  let l = (assert-fails $f7b "F7 erl prints nothing")
  assert ($l | str contains "running OTP") $"F7: the FAIL line must name running OTP; got: ($l)"

  # F8: erl not on PATH.
  let l = (assert-fails $f8 "F8 erl not on PATH")
  assert ($l | str contains "running OTP") $"F8: the FAIL line must name running OTP; got: ($l)"

  # F9: running drift above the floor.
  let l = (assert-fails $f9 "F9 pin 28.5.0.8, erl 28.5.0.9")
  assert ($l | str contains "does not match") $"F9: the FAIL line must say does not match; got: ($l)"

  # F10: record-form pin.
  assert-passes $f10 "F10 erlang = { version = \"28.5.0.8\" }"

  # F11: real-repo default. The real mise.toml pin must clear the floor (RED
  # until the pin is bumped; RED again if it is reverted).
  assert-passes $f11 $"F11 real repo mise.toml \(erlang = ($real_pin)\)"

  # F13: a non-record [tools] prints a FAIL line, not a nu error.
  let l = (assert-fails $f13 "F13 tools = \"x\"")
  assert ($l | str contains "pins no erlang") $"F13: a non-record tools must read as no pin; got: ($l)"

  print "PASS test:otp-audit"
}
