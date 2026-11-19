#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly ROOT_DIR

readonly PLATFORMS="linux-x86_64 linux-aarch64"

fail() {
  echo "error: $*" >&2
  exit 1
}

download() {
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --connect-timeout 30 --max-time 900 \
    --retry 3 --retry-delay 5 \
    --output "$2" "$1"
}

sha256_of() {
  sha256sum "$1" | cut -d ' ' -f 1
}

verify_sha256() {
  local actual
  actual=$(sha256_of "$1")

  [[ $actual == "$2" ]] || fail "checksum mismatch for $1: expected $2, got $actual"
}

validate_version() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+((alpha|beta|RC)[0-9]+)?$ ]] || fail "invalid PHP version: $1"
}

is_prerelease() {
  [[ $1 =~ (alpha|beta|RC)[0-9]+$ ]]
}

validate_source_url() {
  local version=$1 url=$2

  if is_prerelease "$version"; then
    [[ $url =~ ^https://downloads\.php\.net/~[a-z0-9_-]+/php-${version//./\\.}\.tar\.xz$ ]] || fail "unexpected source URL for PHP $version: $url"
  else
    [[ $url == "https://www.php.net/distributions/php-${version}.tar.xz" ]] || fail "unexpected source URL for PHP $version: $url"
  fi
}

verify_php_signature() {
  local version=$1 tarball=$2 signature=$3
  local branch=${version%.*}
  local allowed
  allowed=$(awk -v branch="$branch" '$1 == branch { print $2 }' "$ROOT_DIR/config/php-release-keys.txt")
  [[ -n $allowed ]] || fail "no release manager key for PHP $branch in config/php-release-keys.txt"

  local home status signer
  home=$(mktemp -d)
  chmod 0700 "$home"
  gpg --homedir "$home" --batch --quiet --import "$ROOT_DIR/config/php-release-keys.asc"
  status=$(gpg --homedir "$home" --batch --status-fd 1 --verify "$signature" "$tarball" 2>/dev/null || true)
  rm -rf "$home"

  grep -q '^\[GNUPG:\] REVKEYSIG ' <<<"$status" && fail "$tarball is signed by a revoked key"
  signer=$(sed -n 's/^\[GNUPG:\] VALIDSIG .* \([0-9A-F]\{40\}\)$/\1/p' <<<"$status")
  [[ -n $signer ]] || fail "invalid signature for $tarball: $status"
  grep -qxF "$signer" <<<"$allowed" || fail "$tarball is signed by $signer, which is not a release manager key for PHP $branch"
  echo "$signer"
}

validate_sha256() {
  [[ $1 =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA-256 digest: $1"
}

validate_platform() {
  local platform
  for platform in $PLATFORMS; do
    [[ $1 == "$platform" ]] && return 0
  done
  fail "unsupported platform: $1 (expected one of: $PLATFORMS)"
}

release_tag() {
  echo "v$1"
}

release_state() {
  local answer tag
  tag=$(release_tag "$1")
  if answer=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft --jq .isDraft 2>&1); then
    case $answer in
    true) echo draft ;;
    false) echo published ;;
    *) fail "unexpected answer from [gh release view $tag]: [$answer]" ;;
    esac
  elif [[ $answer == *"release not found"* ]]; then
    echo absent
  else
    fail "cannot read release [$tag]: [$answer]"
  fi
}

xdebug_of_branch() {
  local branch=${1%.*}
  local entry entry_branch entry_version entry_sha256
  for entry in "${XDEBUG_BRANCH_VERSIONS[@]}"; do
    read -r entry_branch entry_version entry_sha256 <<<"$entry"
    [[ $entry_branch == "$branch" ]] || continue
    validate_sha256 "$entry_sha256"
    echo "$entry_version $entry_sha256"
    return 0
  done
  echo "$XDEBUG_VERSION $XDEBUG_SHA256"
}

extensions_csv() {
  local branch=${1%.*}
  local excluded
  excluded=$(awk -v branch="$branch" '$1 == branch { print $2 }' "$ROOT_DIR/config/extensions-excluded.txt")
  grep -Ev '^[[:space:]]*(#|$)' "$ROOT_DIR/config/extensions.txt" | grep -vxF -e "$excluded" | paste -sd , -
}
