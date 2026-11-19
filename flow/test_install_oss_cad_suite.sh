#!/usr/bin/env bash
# flow/test_install_oss_cad_suite.sh (issue #350): regression for the shared
# pinned-OSS-CAD-Suite installer. Needs no network and no real toolchain: the
# transport is a stub `curl` that copies a tiny fixture tarball (or corrupts
# it, on demand), the tool binaries inside the fixture are stub scripts whose
# version strings the test pins, and tar/sha256sum run for real. Covers the
# caller scenarios: empty cache (fetch + extract + stamp), second run over a
# valid unpacked tree (reuse), a matching stamp with the archive absent
# (offline reuse), a corrupt cached archive beside a valid tree (refetch and
# verify before use), a refetch that fails verification (abort, tree kept),
# re-extraction from a cached archive without a refetch, and the yosys /
# nextpnr version guard. Exit nonzero on any mismatch.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
rc_all=0
expect() {  # expect <name> <want> <got>
    if [[ "$3" == "$2" ]]; then echo "ok   $1"; else echo "FAIL $1: want $2 got $3"; rc_all=1; fi
}
val() {  # val <var-name> <declare -p output> -> its value
    sed -n "s/^declare -- $1=\"\(.*\)\"\$/\1/p" <<<"$2"
}

# --- fixture: a miniature oss-cad-suite tarball with stub version strings
FIX="$T/fixture"
mkdir -p "$FIX/oss-cad-suite/bin" "$FIX/oss-cad-suite/lib" \
         "$FIX/oss-cad-suite/libexec" "$FIX/oss-cad-suite/share/yosys" \
         "$FIX/oss-cad-suite/share/nextpnr" "$FIX/oss-cad-suite/etc"
cat >"$FIX/oss-cad-suite/bin/yosys" <<'S'
#!/usr/bin/env bash
echo "Yosys TESTYOSYS (stub install_oss_cad_suite fixture)"
S
cat >"$FIX/oss-cad-suite/bin/nextpnr-generic" <<'S'
#!/usr/bin/env bash
echo "stub nextpnr-9.9.9-STUB (fixture)"
S
chmod +x "$FIX/oss-cad-suite/bin/yosys" "$FIX/oss-cad-suite/bin/nextpnr-generic"
touch "$FIX/oss-cad-suite/lib/l" "$FIX/oss-cad-suite/libexec/x" \
      "$FIX/oss-cad-suite/share/yosys/y" "$FIX/oss-cad-suite/share/nextpnr/n" \
      "$FIX/oss-cad-suite/etc/e"
TGZ="$T/oss-cad-suite-fake.tgz"
tar -czf "$TGZ" -C "$FIX" oss-cad-suite
SHA="$(sha256sum "$TGZ" | cut -d' ' -f1)"

# --- test pins: callers source the real flow/tool_versions.sh first, then
# --- this file replaces the release pins with the fixture's
cat >"$T/test-pins.sh" <<EOF
RECORDED_OSS_CAD_TAG="local-fixture"
RECORDED_OSS_CAD_TARBALL="oss-cad-suite-fake.tgz"
RECORDED_OSS_CAD_SHA256="$SHA"
RECORDED_YOSYS_VERSION="TESTYOSYS"
RECORDED_NEXTPNR_VERSION="nextpnr-9.9.9-STUB"
EOF

# --- stub curl: copies the fixture to the -o target; corrupts on demand and
# --- logs every invocation so the tests can count fetches
STUBS="$T/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/curl" <<'S'
#!/usr/bin/env bash
target=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && target="$a"
    prev="$a"
done
if [[ -z "$target" ]]; then echo "curl stub: no -o target" >&2; exit 2; fi
if [[ "${CURL_STUB_CORRUPT:-0}" == 1 ]]; then
    printf 'not a tarball; the sha256 will not match\n' >"$target"
else
    cp "$CURL_STUB_FIXTURE" "$target"
fi
echo fetched >>"$CURL_STUB_LOG"
S
chmod +x "$STUBS/curl"
export CURL_STUB_FIXTURE="$TGZ"

# run_install <build-dir> [corrupt-fetch]: sources the real pins, then the
# fixture pins, then the installer, under the caller-side set -euo pipefail
# the real callers run with. Prints the version banner plus a declare -p line
# for each state variable the installer sets.
run_install() {  # run_install <build-dir> [CURL_STUB_CORRUPT]
    local build="$1" corrupt="${2:-0}"
    (
        set -euo pipefail
        export PATH="$STUBS:$PATH"
        export CURL_STUB_LOG CURL_STUB_CORRUPT="$corrupt"
        # shellcheck source=flow/tool_versions.sh
        source "$HERE/tool_versions.sh"
        source "$T/test-pins.sh"
        # shellcheck source=flow/install_oss_cad_suite.sh
        source "$HERE/install_oss_cad_suite.sh"
        install_oss_cad_suite "$build"
        declare -p OSS OSS_FETCHED YV NV
    )
}
fresh_curl_log() {  # set CURL_STUB_LOG (in the current shell) to a fresh log
    CURL_LOG="$T/$1.log"; : >"$CURL_LOG"; export CURL_STUB_LOG="$CURL_LOG"
}
LOG="$T/curl1.log"; fresh_curl_log curl1

# --- 1. empty cache: fetch, verify, extract, stamp, put on PATH, check pins
B1="$T/build1"; fresh_curl_log curl1; LOG="$CURL_LOG"
out="$(run_install "$B1")"; rc=$?
expect "empty cache: exit 0" 0 "$rc"
expect "empty cache: version banner" \
    "=== yosys TESTYOSYS (pinned TESTYOSYS), nextpnr-9.9.9-STUB (pinned nextpnr-9.9.9-STUB) ===" \
    "$(head -1 <<<"$out")"
expect "empty cache: fetched flag" 1 "$(val OSS_FETCHED "$out")"
expect "empty cache: OSS path" "$B1/oss-cad-suite" "$(val OSS "$out")"
expect "empty cache: yosys version parsed" "TESTYOSYS" "$(val YV "$out")"
expect "empty cache: nextpnr version parsed" "nextpnr-9.9.9-STUB" "$(val NV "$out")"
expect "empty cache: one fetch" 1 "$(wc -l <"$LOG")"
expect "empty cache: .pin stamp" "$SHA" "$(cat "$B1/oss-cad-suite/.pin")"
[[ -x "$B1/oss-cad-suite/bin/nextpnr-generic" ]]; expect "empty cache: tree extracted" 0 "$?"
expect "empty cache: archive verified into dl" "$SHA" \
    "$(sha256sum "$B1/dl/oss-cad-suite-fake.tgz" | cut -d' ' -f1)"

# --- 2. second run over the valid tree + valid cached archive: reuse, no fetch
fresh_curl_log curl2; LOG="$CURL_LOG"
out="$(run_install "$B1")"; rc=$?
expect "second run: exit 0" 0 "$rc"
expect "second run: reuse flag" 0 "$(val OSS_FETCHED "$out")"
expect "second run: no fetch" 0 "$(wc -l <"$LOG")"

# --- 3. matching stamp with the archive absent: offline reuse, no fetch
B3="$T/build3"; mkdir -p "$B3"
cp -a "$B1/oss-cad-suite" "$B3/oss-cad-suite"
fresh_curl_log curl3; LOG="$CURL_LOG"
out="$(run_install "$B3")"; rc=$?
expect "offline reuse: exit 0" 0 "$rc"
expect "offline reuse: reuse flag" 0 "$(val OSS_FETCHED "$out")"
expect "offline reuse: no fetch" 0 "$(wc -l <"$LOG")"

# --- 3b. tree present but .pin missing, valid cached archive: re-extract
# --- from the cache WITHOUT a refetch
B4="$T/build4"; mkdir -p "$B4/dl"
cp -a "$B1/oss-cad-suite" "$B4/oss-cad-suite"
rm "$B4/oss-cad-suite/.pin"
cp "$B1/dl/oss-cad-suite-fake.tgz" "$B4/dl/"
fresh_curl_log curl4; LOG="$CURL_LOG"
out="$(run_install "$B4")"; rc=$?
expect "stampless tree: exit 0" 0 "$rc"
expect "stampless tree: re-extracted" 1 "$(val OSS_FETCHED "$out")"
expect "stampless tree: no refetch" 0 "$(wc -l <"$LOG")"
expect "stampless tree: .pin rewritten" "$SHA" "$(cat "$B4/oss-cad-suite/.pin")"

# --- 5. corrupt cached archive beside a valid tree: refetch and verify
# --- before use; the tree is re-extracted from the good archive
B5="$T/build5"; mkdir -p "$B5/dl"
cp -a "$B1/oss-cad-suite" "$B5/oss-cad-suite"
printf 'corrupt cached archive\n' >"$B5/dl/oss-cad-suite-fake.tgz"
fresh_curl_log curl5; LOG="$CURL_LOG"
out="$(run_install "$B5")"; rc=$?
expect "corrupt cache: exit 0" 0 "$rc"
expect "corrupt cache: refetched+extracted" 1 "$(val OSS_FETCHED "$out")"
expect "corrupt cache: one refetch" 1 "$(wc -l <"$LOG")"
expect "corrupt cache: cache repaired" "$SHA" \
    "$(sha256sum "$B5/dl/oss-cad-suite-fake.tgz" | cut -d' ' -f1)"
expect "corrupt cache: .pin stamp" "$SHA" "$(cat "$B5/oss-cad-suite/.pin")"

# --- 6. refetch that fails verification: abort, keep the valid tree
B6="$T/build6"; mkdir -p "$B6/dl"
cp -a "$B1/oss-cad-suite" "$B6/oss-cad-suite"
printf 'corrupt cached archive\n' >"$B6/dl/oss-cad-suite-fake.tgz"
fresh_curl_log curl6; LOG="$CURL_LOG"
out="$(run_install "$B6" 1 2>&1)"; rc=$?
expect "bad refetch: nonzero exit" 1 "$rc"
expect "bad refetch: fetch attempted then rejected" 1 "$(wc -l <"$LOG")"
[[ -x "$B6/oss-cad-suite/bin/nextpnr-generic" ]] \
    && [[ "$(cat "$B6/oss-cad-suite/.pin")" == "$SHA" ]]
expect "bad refetch: existing tree untouched" 0 "$?"
grep -q "sha256sum\|FAILED\|WARNING" <<<"$out" || grep -qi "hash" <<<"$out"
expect "bad refetch: names the verification failure" 0 "$?"

# --- 7. version guard: a reused tree whose tools report unpinned versions
B7="$T/build7"; mkdir -p "$B7"
cp -a "$B1/oss-cad-suite" "$B7/oss-cad-suite"
cat >"$B7/oss-cad-suite/bin/yosys" <<'S'
#!/usr/bin/env bash
echo "Yosys DRIFTED (wrong version)"
S
chmod +x "$B7/oss-cad-suite/bin/yosys"
fresh_curl_log curl7; LOG="$CURL_LOG"
out="$(run_install "$B7" 2>&1)"; rc=$?
expect "version guard: nonzero exit" 1 "$rc"
expect "version guard: no fetch (reuse path first)" 0 "$(wc -l <"$LOG")"
grep -q "toolchain version mismatch" <<<"$out"
expect "version guard: mismatch message" 0 "$?"

exit "$rc_all"
