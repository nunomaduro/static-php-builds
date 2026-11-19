#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/../config/build.env"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_SERVER_URL:?GITHUB_SERVER_URL is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

version=${1:-}
dist=${2:-}

validate_version "$version"
xdebug=$(xdebug_of_branch "$version")
read -r XDEBUG_VERSION _ <<<"$xdebug"
[[ -d $dist ]] || fail "usage: publish-release.sh <version> <dist-dir>"

cd "$dist"

expected=()
for platform in $PLATFORMS; do
  expected+=("php-${version}-${platform}.tar.gz")
  [[ -f "php-${version}-${platform}.tar.gz" ]] || fail "missing php-${version}-${platform}.tar.gz"
done

[[ -f SHA256SUMS ]] || fail "missing SHA256SUMS, run scripts/write-checksums.sh first"
actual_count=$(find . -maxdepth 1 -type f | wc -l | tr -d ' ')
((actual_count == ${#expected[@]} + 1)) || fail "expected ${#expected[@]} tarballs and SHA256SUMS in $dist, found $actual_count files"
sha256sum --check --strict SHA256SUMS

tag=$(release_tag "$version")
state=$(release_state "$version")

notes=$(
  cat <<EOF
PHP ${version} for Linux (x86_64, aarch64; glibc ${GLIBC_VERSION}+).

Includes Composer ${COMPOSER_VERSION} and Xdebug ${XDEBUG_VERSION} (off by default; enable with \`XDEBUG_MODE\`). Built with static-php-cli ${SPC_VERSION} from the official php.net source (SHA-256 and release manager signature verified). The checksum of every other source that went into the build is in \`share/sources.txt\`.

Built from ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit/${GITHUB_SHA} in ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}.

Extensions: $(extensions_csv "$version" | sed 's/,/, /g')

Verify a download:

\`\`\`
gh attestation verify php-${version}-linux-x86_64.tar.gz --repo ${GITHUB_REPOSITORY}
\`\`\`
EOF
)

if [[ $state == published ]]; then
  gh release upload "$tag" --repo "$GITHUB_REPOSITORY" --clobber "${expected[@]}" SHA256SUMS
  gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --notes "$notes"
  echo "Replaced the files of PHP $version"
  exit 0
fi

if [[ $state == draft ]]; then
  gh release delete "$tag" --repo "$GITHUB_REPOSITORY" --yes
fi

latest=false

if ! is_prerelease "$version"; then
  highest=$({ gh release list --repo "$GITHUB_REPOSITORY" --exclude-drafts --limit 1000 --json tagName --jq '.[].tagName | ltrimstr("v")'; echo "$version"; } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
  [[ $highest == "$version" ]] && latest=true
fi

gh release create "$tag" \
  --repo "$GITHUB_REPOSITORY" \
  --target "$GITHUB_SHA" \
  --title "PHP $version" \
  --notes "$notes" \
  --latest="$latest" \
  --draft \
  "${expected[@]}" SHA256SUMS

gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false

echo "Published PHP $version"
