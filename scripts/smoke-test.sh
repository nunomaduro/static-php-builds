#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../config/build.env"

tarball=${1:-}
version=${2:-}

[[ -f $tarball ]] || fail "usage: smoke-test.sh <tarball> <version>"
validate_version "$version"
xdebug=$(xdebug_of_branch "$version")
read -r XDEBUG_VERSION _ <<<"$xdebug"

prefix=$(mktemp -d)
trap 'rm -rf "$prefix"' EXIT

tar -xzf "$tarball" -C "$prefix"

php="$prefix/bin/php"
trusted_url="https://repo.packagist.org/packages.json"
untrusted_url="https://untrusted-root.badssl.com/"

check() {
  echo "- $1"
}

actual=$("$php" -r 'echo PHP_VERSION;')
[[ $actual == "$version" ]] || fail "expected PHP $version, got $actual"
check "PHP $actual"

startup=$("$php" -v 2>&1)
if grep -qiE 'warning|error|cannot load' <<<"$startup"; then
  fail "PHP printed problems on startup: $startup"
fi
check "starts without warnings"

missing=$("$php" -- "$(extensions_csv "$version")" <<'PHP'
<?php
$aliases = ["opcache" => "Zend OPcache"];
$missing = [];
foreach (explode(",", $argv[1]) as $extension) {
  if ($extension === "mbregex") {
    $loaded = function_exists("mb_ereg");
  } else {
    $loaded = extension_loaded($aliases[$extension] ?? $extension);
  }
  if (! $loaded) {
    $missing[] = $extension;
  }
}
echo implode(",", $missing);
PHP
)
[[ -z $missing ]] || fail "missing extensions: $missing"
check "all extensions in config/extensions.txt are loaded"

xdebug_version=$("$php" -r 'echo phpversion("xdebug");')
[[ $xdebug_version == "$XDEBUG_VERSION" ]] || fail "expected Xdebug $XDEBUG_VERSION, got [$xdebug_version]"
check "Xdebug $xdebug_version loads"

pcre_jit=$("$php" -r 'echo ini_get("pcre.jit");')
[[ $pcre_jit == 0 ]] || fail "expected pcre.jit=0, got [$pcre_jit]"
check "PCRE JIT is off"

memory_limit=$("$php" -r 'echo ini_get("memory_limit");')
[[ $memory_limit == -1 ]] || fail "expected memory_limit=-1, got [$memory_limit]"
check "memory limit is off"

# shellcheck disable=SC2016 # PHP code, not shell
default_modes=$(env -u XDEBUG_MODE "$php" -r 'echo implode(",", xdebug_info("mode"));')
[[ -z $default_modes ]] || fail "Xdebug should be off by default, but these modes are active: $default_modes"
check "Xdebug is off by default"

# shellcheck disable=SC2016 # PHP code, not shell
enabled_modes=$(XDEBUG_MODE=debug,coverage "$php" -r '$modes = xdebug_info("mode"); sort($modes); echo implode(",", $modes);')
[[ $enabled_modes == "coverage,debug" ]] || fail "XDEBUG_MODE=debug,coverage did not enable Xdebug, active modes: $enabled_modes"
check "XDEBUG_MODE enables Xdebug"

"$php" <<'PHP' || fail "PDO SQLite does not work"
<?php
$db = new PDO("sqlite::memory:");
$db->exec("create table users (name text)");
$db->exec("insert into users values (\"taylor\")");
exit($db->query("select name from users")->fetchColumn() === "taylor" ? 0 : 1);
PHP
check "PDO SQLite works"

"$php" <<'PHP' || fail "intl does not work"
<?php
exit((new NumberFormatter("en_US", NumberFormatter::CURRENCY))->formatCurrency(1, "USD") === "$1.00" ? 0 : 1);
PHP
check "intl works"

readonly HTTPS_CHECK_ATTEMPTS=3
readonly HTTPS_CHECK_RETRY_DELAY_SECONDS=15

run_https_check() {
  local url=$1 script=$2
  local attempt
  for ((attempt = 1; attempt <= HTTPS_CHECK_ATTEMPTS; attempt++)); do
    "$php" -- "$url" <<<"$script" && return 0
    ((attempt < HTTPS_CHECK_ATTEMPTS)) || break
    echo "the HTTPS check of [$url] failed on attempt [$attempt] of [$HTTPS_CHECK_ATTEMPTS]; next attempt in [$HTTPS_CHECK_RETRY_DELAY_SECONDS] seconds" >&2
    sleep "$HTTPS_CHECK_RETRY_DELAY_SECONDS"
  done
  return 1
}

stream_accepts_trusted=$(
  cat <<'PHP'
<?php
$messages = [];
set_error_handler(function (int $level, string $message) use (&$messages): bool {
  $messages[] = $message;
  return true;
});
if (file_get_contents($argv[1]) !== false) {
  exit(0);
}
fwrite(STDERR, implode("\n", $messages) . "\n");
exit(1);
PHP
)

stream_rejects_untrusted=$(
  cat <<'PHP'
<?php
$messages = [];
set_error_handler(function (int $level, string $message) use (&$messages): bool {
  $messages[] = $message;
  return true;
});
$body = file_get_contents($argv[1]);
$errors = implode("\n", $messages);
if ($body === false && str_contains($errors, "certificate verify failed")) {
  exit(0);
}
fwrite(STDERR, ($body === false ? $errors : "the request succeeded") . "\n");
exit(1);
PHP
)

curl_accepts_trusted=$(
  cat <<'PHP'
<?php
$curl = curl_init($argv[1]);
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
if (curl_exec($curl) !== false) {
  exit(0);
}
fwrite(STDERR, "curl error [" . curl_errno($curl) . "]: [" . curl_error($curl) . "]\n");
exit(1);
PHP
)

curl_rejects_untrusted=$(
  cat <<'PHP'
<?php
$curl = curl_init($argv[1]);
curl_setopt($curl, CURLOPT_RETURNTRANSFER, true);
$body = curl_exec($curl);
if ($body === false && curl_errno($curl) === CURLE_SSL_CACERT) {
  exit(0);
}
fwrite(STDERR, ($body === false ? "curl error [" . curl_errno($curl) . "]: [" . curl_error($curl) . "]" : "the request succeeded") . "\n");
exit(1);
PHP
)

run_https_check "$trusted_url" "$stream_accepts_trusted" || fail "stream HTTPS requests to [$trusted_url] fail (CA certificates not found?)"
check "stream HTTPS requests work with the system CA certificates"

run_https_check "$untrusted_url" "$stream_rejects_untrusted" || fail "stream HTTPS does not reject the untrusted certificate of [$untrusted_url]"
check "stream HTTPS rejects an untrusted certificate"

run_https_check "$trusted_url" "$curl_accepts_trusted" || fail "curl HTTPS requests to [$trusted_url] fail (CA certificates not found?)"
check "curl HTTPS requests work with the system CA certificates"

run_https_check "$untrusted_url" "$curl_rejects_untrusted" || fail "curl HTTPS does not reject the untrusted certificate of [$untrusted_url]"
check "curl HTTPS rejects an untrusted certificate"

composer_version=$("$prefix/bin/composer" --version --no-ansi 2>/dev/null)
[[ $composer_version == "Composer version ${COMPOSER_VERSION} "* ]] || fail "unexpected Composer output: $composer_version"
check "Composer $COMPOSER_VERSION runs"

newest_glibc=$(objdump -T "$prefix/libexec/php" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -V | tail -n 1)
if [[ $(printf '%s\n%s\n' "$newest_glibc" "$GLIBC_VERSION" | sort -V | tail -n 1) != "$GLIBC_VERSION" ]]; then
  fail "binary needs glibc $newest_glibc, newer than the $GLIBC_VERSION baseline"
fi
check "needs glibc $newest_glibc at most"

echo "Smoke test passed for $(basename "$tarball")"
