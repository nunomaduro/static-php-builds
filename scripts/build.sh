#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../config/build.env"

version=${1:-}
php_sha256=${2:-}
platform=${3:-}
source_url=${4:-}

validate_version "$version"
validate_sha256 "$php_sha256"
validate_platform "$platform"
validate_source_url "$version" "$source_url"
xdebug=$(xdebug_of_branch "$version")
read -r XDEBUG_VERSION XDEBUG_SHA256 <<<"$xdebug"

github_token=${GITHUB_TOKEN:-}
unset GITHUB_TOKEN

umask 022
ulimit -n "$(ulimit -Hn)"

work="$ROOT_DIR/.build/$platform"
dist="$ROOT_DIR/dist"

clear_work_except_caches() {
  local path
  for path in "$work"/* "$work"/.[!.]*; do
    [[ -e $path ]] || continue
    case $(basename "$path") in
    buildroot | downloads | pkgroot) ;;
    *) rm -rf "$path" ;;
    esac
  done
}

remove_cached_php() {
  rm -rf "$work/buildroot/bin/php" "$work/buildroot/bin/php-config" "$work/buildroot/bin/phpize" \
    "$work/buildroot/include/php" "$work/buildroot/lib/php" "$work/buildroot/modules"
  rm -f "$work"/downloads/php-*.tar.xz
}

readonly SPC_DOWNLOAD_ATTEMPTS=4
readonly SPC_DOWNLOAD_RETRY_DELAY_SECONDS=120

spc_download_once() {
  if [[ -n $github_token ]]; then
    GITHUB_TOKEN=$github_token "$work/spc" download "$@"
  else
    "$work/spc" download "$@"
  fi
}

spc_download() {
  local attempt
  for ((attempt = 1; attempt <= SPC_DOWNLOAD_ATTEMPTS; attempt++)); do
    spc_download_once "$@" && return 0
    ((attempt < SPC_DOWNLOAD_ATTEMPTS)) || break
    echo "the download of the sources failed on attempt [$attempt] of [$SPC_DOWNLOAD_ATTEMPTS]; next attempt in [$SPC_DOWNLOAD_RETRY_DELAY_SECONDS] seconds" >&2
    sleep "$SPC_DOWNLOAD_RETRY_DELAY_SECONDS"
  done
  fail "the download of the sources failed after [$SPC_DOWNLOAD_ATTEMPTS] attempts"
}

verify_sources_lock() {
  local sources=$1 php_source=$2
  local lock="$ROOT_DIR/config/sources.lock"
  local drift
  drift=$(grep -vF "  $(basename "$php_source")" <<<"$sources" | grep -vxF -f "$lock" || true)
  [[ -n $drift ]] || return 0
  mkdir -p "$work/log"
  echo "$drift" >"$work/log/sources.drift"
  echo "$drift" >&2
  fail "these sources are not in config/sources.lock; review the upstream change, then replace their lines in the lock"
}

print_build_log_on_failure() {
  local status=$?
  local log="$work/log/spc.shell.log"
  if ((status != 0)) && [[ -f $log ]]; then
    echo "::endgroup::"
    echo "Last 150 lines of $log:"
    tail -n 150 "$log"
  fi
  return "$status"
}

clear_work_except_caches
remove_cached_php
trap print_build_log_on_failure EXIT
mkdir -p "$work" "$dist"
cd "$work"

case "$platform" in
linux-x86_64)
  spc_asset=spc-linux-x86_64.tar.gz
  spc_sha256=$SPC_SHA256_LINUX_X86_64
  zig_package=zig-x86_64-linux
  export SPC_TARGET="x86_64-linux-gnu.${GLIBC_VERSION}"
  ;;
linux-aarch64)
  spc_asset=spc-linux-aarch64.tar.gz
  spc_sha256=$SPC_SHA256_LINUX_AARCH64
  zig_package=zig-aarch64-linux
  export SPC_TARGET="aarch64-linux-gnu.${GLIBC_VERSION}"
  ;;
esac

url_pins=()
git_pins=()
while read -r pin_kind pin_source pin_target pin_url; do
  case $pin_kind in
  url)
    [[ $pin_target =~ ^[A-Za-z0-9._-]+$ ]] || fail "the pin of [$pin_source] in [config/sources.pins] has an invalid file name [$pin_target]"
    [[ $pin_url == https://* ]] || fail "the pin of [$pin_source] in [config/sources.pins] has no https URL"
    url_pins+=("$pin_source $pin_target $pin_url")
    ;;
  git)
    [[ $pin_target =~ ^[0-9a-f]{40}$ && -z $pin_url ]] || fail "the pin of [$pin_source] in [config/sources.pins] has no full commit"
    git_pins+=("$pin_source $pin_target")
    ;;
  *) fail "the pin of [$pin_source] in [config/sources.pins] has an unknown kind [$pin_kind]" ;;
  esac
done <"$ROOT_DIR/config/sources.pins"

download_url_pins() {
  local pin source file url
  pin_options=()
  for pin in "${url_pins[@]}"; do
    read -r source file url <<<"$pin"
    download "$url" "$work/pins/$file"
    pin_options+=("--custom-url=${source}:file://$work/pins/$file")
  done
}

check_out_git_pins() {
  local pin source commit clone
  for pin in "${git_pins[@]}"; do
    read -r source commit <<<"$pin"
    clone="$work/downloads/$source"
    [[ -d $clone ]] || continue
    git -C "$clone" checkout --quiet --detach "$commit" || fail "the clone of [$source] has no commit [$commit]"
    git -C "$clone" submodule update --quiet --recursive
  done
}

record_sources() {
  local path name
  for path in "$work"/downloads/*; do
    name=$(basename "$path")
    if [[ -d $path/.git ]]; then
      echo "git:$(git -C "$path" rev-parse HEAD)  $name"
    elif [[ -f $path ]]; then
      echo "sha256:$(sha256_of "$path")  $name"
    else
      fail "unexpected download [$path]"
    fi
  done
}

echo "::group::Download static-php-cli $SPC_VERSION"
download "https://github.com/crazywhalecc/static-php-cli/releases/download/${SPC_VERSION}/${spc_asset}" "$work/spc.tar.gz"
verify_sha256 "$work/spc.tar.gz" "$spc_sha256"
tar -xzf "$work/spc.tar.gz" -C "$work" spc
chmod 0755 "$work/spc"
"$work/spc" --version
echo "::endgroup::"

extensions=$(extensions_csv "$version")
branch=${version%.*}

if [[ $branch == 8.6 ]]; then
  export SPC_MICRO_PATCHES=disable_huge_page_84
  export SPC_CMD_PREFIX_PHP_CONFIGURE="./configure ac_cv_have_decl_epoll_pwait2=no --prefix=--with-valgrind=no --disable-shared --enable-static --disable-all --disable-phpdbg --enable-rtld-now --enable-re2c-cgoto --disable-rpath --enable-pic"
fi

echo "::group::Install build tools"
zig_file="${zig_package}-${ZIG_VERSION}.tar.xz"
mkdir -p "$work/pins"
download "https://ziglang.org/download/${ZIG_VERSION}/${zig_file}" "$work/pins/$zig_file"
"$work/spc" install-pkg "$zig_package" --custom-url="${zig_package}:file://$work/pins/$zig_file"
"$work/spc" doctor --auto-fix
echo "::endgroup::"

echo "::group::Download sources"
mirror_options=()
for mirror in "${SPC_SOURCE_MIRRORS[@]}"; do
  read -r mirror_source mirror_sha256 mirror_url <<<"$mirror"
  validate_sha256 "$mirror_sha256"
  mirror_options+=("--custom-url=${mirror_source}:${mirror_url}")
done
download_url_pins

spc_download \
  "${mirror_options[@]}" \
  "${pin_options[@]}" \
  --with-php="$branch" \
  --for-extensions="${extensions},xdebug" \
  --custom-url="php-src:${source_url}" \
  --custom-url="xdebug:https://xdebug.org/files/xdebug-${XDEBUG_VERSION}.tgz" \
  --retry=3
check_out_git_pins

php_source="$work/downloads/php-${version}.tar.xz"
[[ -f $php_source ]] || fail "PHP source not found at $php_source"
verify_sha256 "$php_source" "$php_sha256"
php_signature="$work/php-${version}.tar.xz.asc"
download "${source_url}.asc" "$php_signature"
php_signer=$(verify_php_signature "$version" "$php_source" "$php_signature")
echo "PHP source signed by $php_signer"
xdebug_source="$work/downloads/xdebug-${XDEBUG_VERSION}.tgz"
[[ -f $xdebug_source ]] || fail "Xdebug source not found at $xdebug_source"
verify_sha256 "$xdebug_source" "$XDEBUG_SHA256"
for mirror in "${SPC_SOURCE_MIRRORS[@]}"; do
  read -r mirror_source mirror_sha256 mirror_url <<<"$mirror"
  mirror_file="$work/downloads/$(basename "$mirror_url")"
  [[ -f $mirror_file ]] || fail "source $mirror_source not found at $mirror_file"
  verify_sha256 "$mirror_file" "$mirror_sha256"
done
sources=$(record_sources)
echo "$sources"
verify_sources_lock "$sources" "$php_source"
echo "::endgroup::"

php_patch=
case $branch in
8.3) php_patch=php-8.3-avx512-cache.patch ;;
8.6) php_patch=php-8.6-libcxx-snprintf.patch ;;
esac

if [[ -n $php_patch ]]; then
  echo "::group::Patch PHP $version"
  "$work/spc" extract php-src
  patch -p1 -d "$work/source/php-src" <"$ROOT_DIR/patches/$php_patch"
  echo "::endgroup::"
fi

if [[ ,$extensions, == *,imagick,* ]]; then
  echo "::group::Patch libde265"
  "$work/spc" extract libde265
  patch -p1 -d "$work/source/libde265" <"$ROOT_DIR/patches/libde265-avx-off.patch"
  echo "::endgroup::"
fi

echo "::group::Build PHP $version"
"$work/spc" build "$extensions" \
  --build-cli \
  --build-shared=xdebug \
  --with-suggested-libs
echo "::endgroup::"

echo "::group::Package"
stage="$work/stage"
mkdir -p "$stage/bin" "$stage/libexec" "$stage/lib/php/extensions" "$stage/etc/php/conf.d" "$stage/share"

install -m 0755 "$work/buildroot/bin/php" "$stage/libexec/php"
install -m 0755 "$work/buildroot/modules/xdebug.so" "$stage/lib/php/extensions/xdebug.so"
install -m 0755 "$ROOT_DIR/stubs/php" "$stage/bin/php"
install -m 0755 "$ROOT_DIR/stubs/composer" "$stage/bin/composer"
install -m 0644 "$ROOT_DIR/stubs/xdebug.ini" "$stage/etc/php/conf.d/xdebug.ini"
install -m 0644 "$ROOT_DIR/stubs/pcre.ini" "$stage/etc/php/conf.d/pcre.ini"
install -m 0644 "$ROOT_DIR/stubs/memory.ini" "$stage/etc/php/conf.d/memory.ini"

download "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" "$work/composer.phar"
verify_sha256 "$work/composer.phar" "$COMPOSER_SHA256"
install -m 0644 "$work/composer.phar" "$stage/libexec/composer.phar"

cp -R "$work/buildroot/license" "$stage/share/licenses"

echo "$sources" >"$stage/share/sources.txt"

cat >"$stage/share/build-info.txt" <<EOF
PHP ${version} (${platform})
PHP source SHA-256: ${php_sha256}
PHP source signed by: ${php_signer}
Commit: ${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse HEAD)}
static-php-cli: ${SPC_VERSION}
Target: ${SPC_TARGET}
Composer: ${COMPOSER_VERSION}
Extensions: ${extensions}
Xdebug: ${XDEBUG_VERSION}
Shared extensions: xdebug
Sources: share/sources.txt
EOF

tarball="$dist/php-${version}-${platform}.tar.gz"
tar --owner=0 --group=0 --numeric-owner -czf "$tarball" -C "$stage" bin etc lib libexec share
echo "::endgroup::"

echo "Built $tarball ($(sha256_of "$tarball"))"
