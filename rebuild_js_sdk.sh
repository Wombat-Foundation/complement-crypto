#!/bin/bash -e
set -o pipefail

JS_SDK_VERSION=$1

if [ -z "$JS_SDK_VERSION" ] || [ "$JS_SDK_VERSION" = "-h" ] || [ "$JS_SDK_VERSION" = "--help" ];
then
    echo "Rebuild the version of JS SDK used. (requires on PATH: corepack, which provides yarn)"
    echo "Usage: $0 [version]"
    echo "  [version]: the yarn/npm package to use. This is fed directly into 'yarn add' so branches/commits can be used"
    echo ""
    echo "Examples:"
    echo "  Install a released version:    $0 matrix-js-sdk@29.1.0"
    echo "  Install develop branch:        $0 matrix-js-sdk@https://github.com/matrix-org/matrix-js-sdk#develop"
    echo "  Install specific commit:       $0 matrix-js-sdk@https://github.com/matrix-org/matrix-js-sdk#36c958642cda08d32bc19c2303ebdfca470d03c1"
    echo "  Install from a local checkout: $0 matrix-js-sdk@file:/path/to/local/js/sdk"
    exit 1
fi

# Fail early with a clear message rather than "corepack: command not found"
# halfway through the rebuild (some Node distributions ship without corepack).
if ! command -v corepack >/dev/null 2>&1; then
    echo "error: corepack not found on PATH, it is required to run yarn" >&2
    exit 1
fi

# Invoke Yarn through Corepack directly instead of installing global shims. This
# works for unprivileged users too: `corepack enable` otherwise needs write
# access to the system Yarn location (for example, /usr/bin on Arch Linux).
#
# `yarn add` records the spec in the tracked internal/api/js/js-sdk/package.json
# and yarn.lock. A local `file:` checkout is a development-only override, so
# snapshot the tracked manifests and restore them once the build is done: no
# absolute or relative filesystem path can then be left in version control.
# Remote specs (GitLab/release/tag) are intentionally left in place, since that
# is how the pinned SDK commit is updated.
case "$JS_SDK_VERSION" in
    *"@file:"*|file:*)
        pkg_backup="$(mktemp)"
        lock_backup="$(mktemp)"
        cp ./internal/api/js/js-sdk/package.json "$pkg_backup"
        cp ./internal/api/js/js-sdk/yarn.lock "$lock_backup"
        trap 'cp "$pkg_backup" ./internal/api/js/js-sdk/package.json; cp "$lock_backup" ./internal/api/js/js-sdk/yarn.lock; rm -f "$pkg_backup" "$lock_backup"' EXIT
        ;;
esac

# Drop any previous install of the SDK first: a stale or cross-checkout entry
# (e.g. a relative symlink left by an earlier `file:` install) makes `yarn add`
# fail with EEXIST or yields a broken symlink into node_modules.
rm -rf ./internal/api/js/js-sdk/node_modules/matrix-js-sdk
(cd ./internal/api/js/js-sdk && corepack yarn add "$1" && corepack yarn install && corepack yarn build)
rm -rf ./internal/api/js/chrome/dist || echo 'no dist directory detected';
cp -r ./internal/api/js/js-sdk/dist/. ./internal/api/js/chrome/dist
