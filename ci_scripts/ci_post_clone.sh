#!/bin/sh
# Xcode Cloud runs this after cloning. Every workflow in this repository ships to
# TestFlight, so a build stops here unless its commit is already on main.
# A failed fetch also stops the build: an unproven commit must not be signed.
set -eu

commit="${CI_COMMIT:?Xcode Cloud did not provide CI_COMMIT}"
cd "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud did not provide CI_PRIMARY_REPOSITORY_PATH}"

if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    git fetch --quiet --unshallow origin
fi
git fetch --quiet --no-tags origin +refs/heads/main:refs/remotes/origin/main

if ! git merge-base --is-ancestor "$commit" refs/remotes/origin/main; then
    echo "error: $commit is not on main; TestFlight builds only ship merged commits." >&2
    exit 1
fi
echo "$commit is on main."
