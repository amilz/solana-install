#!/usr/bin/env bash
# Resolves the latest upstream version for every tool version pinned in
# install.sh and rewrites the pins (and the sample output block in README.md)
# whenever a newer version exists.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/install.sh}"
README="${README:-$REPO_ROOT/README.md}"
# When set, each applied bump is appended here as "Name: old -> new" for the
# workflow to turn into a pull request body.
SUMMARY_FILE="${SUMMARY_FILE:-}"

BUMPED=0

########################################
# Logging Functions
########################################
log_info() {
    printf "[INFO] %s\n" "$1"
}

log_error() {
    printf "[ERROR] %s\n" "$1" >&2
}

########################################
# Semantic version comparison
########################################
# True when ver1 sorts strictly before ver2. Segment counts may differ; missing
# segments count as zero, and every segment is compared numerically.
version_lt() {
    local ver1="${1#v}"
    local ver2="${2#v}"

    local IFS='.'
    read -r -a v1 <<< "${ver1:-0}"
    read -r -a v2 <<< "${ver2:-0}"

    local len="${#v1[@]}"
    if (( ${#v2[@]} > len )); then
        len="${#v2[@]}"
    fi

    local i
    for ((i = 0; i < len; i++)); do
        local num1="${v1[i]:-0}"
        local num2="${v2[i]:-0}"
        if ((10#$num1 < 10#$num2)); then
            return 0
        elif ((10#$num1 > 10#$num2)); then
            return 1
        fi
    done

    return 1
}

# Reads candidate versions on stdin, one per line, and prints the highest one by
# semantic version. Prints nothing when no candidate is a plain numeric version.
max_version() {
    local best="" candidate
    while read -r candidate; do
        candidate="${candidate#v}"
        [[ "$candidate" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
        if [[ -z "$best" ]] || version_lt "$best" "$candidate"; then
            best="$candidate"
        fi
    done
    printf "%s" "$best"
}

########################################
# Upstream version resolution
########################################
github_api() {
    local url="$1"
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl --proto '=https' --tlsv1.2 -sSfL \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer $GITHUB_TOKEN" \
            "$url"
    else
        curl --proto '=https' --tlsv1.2 -sSfL \
            -H "Accept: application/vnd.github+json" \
            "$url"
    fi
}

# Highest stable release version of a GitHub repository. Drafts, prereleases and
# any tag carrying a prerelease suffix (rc, beta, ...) are ignored, and the
# result is chosen by semantic version rather than by publication date or by the
# repository's "latest release" marker.
latest_github_version() {
    local repo="$1"
    github_api "https://api.github.com/repos/${repo}/releases?per_page=100" \
        | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
        | sed 's/^v//' \
        | grep -E '^[0-9]+(\.[0-9]+)*$' \
        | max_version
}

# Highest Node.js version carrying an LTS codename.
latest_node_lts_version() {
    curl --proto '=https' --tlsv1.2 -sSfL https://nodejs.org/dist/index.json \
        | jq -r '.[] | select(.lts) | .version' \
        | sed 's/^v//' \
        | max_version
}

########################################
# Pin rewriting
########################################
# Replaces the first sed-matched pin in a file, in place.
replace_in_file() {
    local file="$1" expression="$2" tmp
    tmp="$(mktemp)"
    sed "$expression" "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

record_bump() {
    local name="$1" current="$2" latest="$3"
    log_info "$name: $current -> $latest"
    if [[ -n "$SUMMARY_FILE" ]]; then
        printf -- "- %s: %s -> %s\n" "$name" "$current" "$latest" >> "$SUMMARY_FILE"
    fi
    BUMPED=1
}

# Compares a pin against its upstream version and, when upstream is strictly
# newer, applies every supplied sed expression with @@LATEST@@ substituted for
# the new version.
bump_pin() {
    local name="$1" current="$2" latest="$3" file="$4"
    shift 4

    if [[ -z "$latest" ]]; then
        log_error "Could not resolve an upstream version for $name."
        return 1
    fi

    if [[ "$current" == "$latest" ]] || ! version_lt "$current" "$latest"; then
        log_info "$name is up to date at $current (upstream latest $latest)."
        return 0
    fi

    local expression
    for expression in "$@"; do
        replace_in_file "$file" "${expression//@@LATEST@@/$latest}"
    done
    record_bump "$name" "$current" "$latest"
}

# Prints the current value of a pin by applying a sed expression that isolates
# the version from its surrounding line.
read_pin() {
    local file="$1" expression="$2" value
    value="$(sed -n "$expression" "$file" | head -n1)"
    if [[ -z "$value" ]]; then
        log_error "Could not read a pinned version from $file using: $expression"
        return 1
    fi
    printf "%s" "$value"
}

########################################
# Main
########################################
for tool in curl jq sed; do
    command -v "$tool" >/dev/null 2>&1 || {
        log_error "$tool is required."
        exit 1
    }
done

anchor_current="$(read_pin "$INSTALL_SH" 's/^[[:space:]]*local ANCHOR_VERSION="\([^"]*\)".*/\1/p')"
surfpool_current="$(read_pin "$INSTALL_SH" 's/^[[:space:]]*local SURFPOOL_VERSION="\([^"]*\)".*/\1/p')"
node_current="$(read_pin "$INSTALL_SH" 's/^[[:space:]]*local node_version="\([^"]*\)".*/\1/p')"
nvm_current="$(read_pin "$INSTALL_SH" 's|.*nvm-sh/nvm/v\([0-9][0-9.]*\)/install\.sh.*|\1|p')"

log_info "Resolving upstream versions..."
anchor_latest="$(latest_github_version "solana-foundation/anchor")"
surfpool_latest="$(latest_github_version "txtx/surfpool")"
nvm_latest="$(latest_github_version "nvm-sh/nvm")"
node_latest="$(latest_node_lts_version)"

bump_pin "Anchor" "$anchor_current" "$anchor_latest" "$INSTALL_SH" \
    's/^\([[:space:]]*local ANCHOR_VERSION=\)"[^"]*"/\1"@@LATEST@@"/'

bump_pin "Surfpool" "$surfpool_current" "$surfpool_latest" "$INSTALL_SH" \
    's/^\([[:space:]]*local SURFPOOL_VERSION=\)"[^"]*"/\1"@@LATEST@@"/'

bump_pin "Node.js" "$node_current" "$node_latest" "$INSTALL_SH" \
    's/^\([[:space:]]*local node_version=\)"[^"]*"/\1"@@LATEST@@"/'

bump_pin "nvm" "$nvm_current" "$nvm_latest" "$INSTALL_SH" \
    's|\(nvm-sh/nvm/v\)[0-9][0-9.]*\(/install\.sh\)|\1@@LATEST@@\2|'

# The "Installed Versions:" sample block in the README quotes the pinned
# versions, so keep the pinned tools in it aligned with install.sh. The Rust and
# Solana CLI lines track floating installs and stay illustrative.
if [[ -f "$README" ]]; then
    anchor_pinned="$(read_pin "$INSTALL_SH" 's/^[[:space:]]*local ANCHOR_VERSION="\([^"]*\)".*/\1/p')"
    surfpool_pinned="$(read_pin "$INSTALL_SH" 's/^[[:space:]]*local SURFPOOL_VERSION="\([^"]*\)".*/\1/p')"
    node_pinned="$(read_pin "$INSTALL_SH" 's/^[[:space:]]*local node_version="\([^"]*\)".*/\1/p')"

    replace_in_file "$README" "s/^\(Anchor CLI: anchor-cli \).*/\1${anchor_pinned}/"
    replace_in_file "$README" "s/^\(Surfpool CLI: surfpool \).*/\1${surfpool_pinned}/"
    replace_in_file "$README" "s/^\(Node.js: v\).*/\1${node_pinned}/"
fi

if ((BUMPED == 0)); then
    log_info "All pinned versions are up to date."
else
    log_info "Pinned versions updated."
fi
