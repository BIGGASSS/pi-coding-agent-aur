#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# update-pkgbuild.sh — update PKGBUILD to the latest pi release
#
# Fetches the latest release tag from the GitHub API, downloads both
# x86_64 and aarch64 tarballs, computes SHA256 checksums, and patches
# pkgver / sha256sums_* in the PKGBUILD.
#
# Usage:  ./update-pkgbuild.sh
# ------------------------------------------------------------------

PKGBUILD="$(dirname "$0")/PKGBUILD"
REPO="earendil-works/pi"

# --- Helper: print error and exit -----------------------------------
die() {
    echo "::error:: $*" >&2
    exit 1
}

# --- 1. Fetch latest release tag from GitHub ------------------------
echo ":: Fetching latest release from $REPO …"
tag="$(
    curl -sfL "https://api.github.com/repos/$REPO/releases/latest" \
        | jq -r '.tag_name'
)" || die "Failed to fetch latest release from GitHub API"

[[ -n "$tag" && "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "Unexpected tag format: '$tag'"

newver="${tag#v}"   # strip leading "v"
echo "   Latest version: $newver (tag: $tag)"

# --- 2. Read current version from PKGBUILD --------------------------
curver="$(sed -n 's/^pkgver=//p' "$PKGBUILD")"
echo "   Current version: $curver"

if [[ "$newver" == "$curver" ]]; then
    echo "   Already up-to-date. Nothing to do."
    exit 0
fi

# --- 3. Download tarballs into a temp directory ---------------------
tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

archs=("x64" "arm64")
arch_labels=("x86_64" "aarch64")
declare -A sums

for i in "${!archs[@]}"; do
    arch="${archs[$i]}"
    label="${arch_labels[$i]}"
    url="https://github.com/$REPO/releases/download/$tag/pi-linux-${arch}.tar.gz"
    tarball="$tmpdir/pi-linux-${label}.tar.gz"

    echo ":: Downloading ${url} …"
    curl -sfL "$url" -o "$tarball" || die "Failed to download $url"

    echo ":: Computing SHA256 for ${label} …"
    sums["$label"]="$(sha256sum "$tarball" | cut -d' ' -f1)"
done

# --- 4. Patch PKGBUILD ----------------------------------------------
echo ":: Updating PKGBUILD …"

# Use a temporary file to build the new PKGBUILD
awk -v newver="$newver" \
    -v sum_x86_64="${sums[x86_64]}" \
    -v sum_aarch64="${sums[aarch64]}" \
'
/^pkgver=/ {
    print "pkgver=" newver
    next
}
/^pkgrel=/ {
    print "pkgrel=1"
    next
}
/^sha256sums_x86_64=\(/ {
    print "sha256sums_x86_64=(\"" sum_x86_64 "\")"
    next
}
/^sha256sums_aarch64=\(/ {
    print "sha256sums_aarch64=(\"" sum_aarch64 "\")"
    next
}
{ print }
' "$PKGBUILD" > "$tmpdir/PKGBUILD.new"

mv "$tmpdir/PKGBUILD.new" "$PKGBUILD"

echo ":: Done! Updated to version $newver"
echo ""
echo "   Changes:"
echo "     pkgver: $curver -> $newver"
echo "     sha256sums_x86_64:  ${sums[x86_64]}"
echo "     sha256sums_aarch64: ${sums[aarch64]}"
echo ""

# --- 5. Commit and push to remote -----------------------------------
cd "$(dirname "$0")"

if git rev-parse --git-dir >/dev/null 2>&1; then
    echo ":: Committing and pushing to remote …"

    git add .

    # Only commit if there are actual changes staged
    if git diff --cached --quiet; then
        echo "   No changes to commit."
    else
        git commit -m "Update to v$newver"

        if git remote -v | grep -q .; then
            current_branch="$(git rev-parse --abbrev-ref HEAD)"
            git push origin "$current_branch"
            echo "   Pushed to origin/$current_branch"
        else
            echo "   No remote configured — skipping push."
        fi
    fi
else
    echo "   Not inside a git repository — skipping commit and push."
fi

echo ""
echo "   Run 'makepkg -si' to build and install."
