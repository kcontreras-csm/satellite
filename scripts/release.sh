#!/bin/zsh
# Cuts a release: pushes main and a version tag. GitHub Actions does the rest: it builds the app with the
# version stamped from the tag and publishes the Release (zip + appcast.json) that the in-app updater reads.
# No files are modified and no commits are created.
#
#   scripts/release.sh 1.2.0
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <major.minor.patch>}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must be major.minor.patch (for example 1.2.0), got '$VERSION'"
    exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "Releases are cut from main (you are on '$BRANCH')."
    echo "  git checkout main && git merge $BRANCH && scripts/release.sh $VERSION"
    exit 1
fi

if ! git diff --quiet HEAD; then
    echo "The working tree has uncommitted changes. Commit or stash them first:"
    echo "the release is built from the tagged commit."
    exit 1
fi

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "Tag v$VERSION already exists."
    exit 1
fi

git push origin main
git tag "v$VERSION"
git push origin "v$VERSION"

REPO=$(git remote get-url origin 2>/dev/null \
    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##') || REPO="<owner>/<repo>"
echo ""
echo "Tagged v$VERSION. GitHub Actions is building the release."
echo "Watch it:  https://github.com/$REPO/actions"
echo "Feed URL:  https://github.com/$REPO/releases/latest/download/appcast.json"
