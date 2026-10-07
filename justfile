# Build and run complement-crypto tests

set dotenv-load

BASE_IMAGE := "ghcr.io/matrix-org/synapse-service:v1.117.0"
COMPLEMENT_DIR := justfile_directory()

# matrix-js-sdk spec passed to `yarn add` by `rebuild-js-sdk`. Defaults to the
# pinned Wombat-Foundation fork on GitLab -- always a git URL, never a local
# path. Override per-invocation or via the LOCAL_JS_SDK environment variable /
# .env entry to test a local checkout (the path must be absolute):
#
#   LOCAL_JS_SDK='matrix-js-sdk@file:/abs/path/to/matrix-js-sdk' just rebuild-js-sdk
LOCAL_JS_SDK := env_var_or_default("LOCAL_JS_SDK", "matrix-js-sdk@https://gitlab.com/Wombat-Foundation/matrix-js-sdk#ba48cf7c768996e17b90d9565109f1ea837b5eea")
RUST_SDK_PROFILE := env_var_or_default("COMPLEMENT_CRYPTO_RUST_SDK_PROFILE", "dev")
RUST_SDK_TARGET_DIR := if RUST_SDK_PROFILE == "dev" { "debug" } else { RUST_SDK_PROFILE }

# Replace the `install-uniffi-bindgen` recipe with this once uniffi-bindgen-go
# gets a release with Uniffi 0.32 support.
# cargo install uniffi-bindgen-go --tag {{ UNIFFI_GO_VERSION }} --git https://github.com/NordSecurity/uniffi-bindgen-go
#
# As such, this variable is not used till we're back on a release of uniffi-bindgen-go
# UNIFFI_GO_VERSION := "v0.7.1+v0.31.0"

# List the available recipes.
default:
    just --list

# Opens a browser with mitmweb. Then you can open a dump file made via COMPLEMENT_CRYPTO_MITMDUMP. (requires on PATH: docker)
open-mitmweb:
    # use python3 instead of xdg-open because it's more portable (xdg-open doesn't work on MacOS). Sleep 1s and do it in the background.
    (sleep 1 && python3 -m webbrowser http://localhost:1445) &
    # use same version as tests so we don't need to pull any new image. When the user CTRL+Cs this, the container quits.
    docker run --rm -p 1445:8081 mitmproxy/mitmproxy:10.1.5  mitmweb --web-host 0.0.0.0

# Run the Rust tests of complement crypto.
test rust-sdk-path pattern="":
    @echo "Using RUST_PATH: $(realpath {{ rust-sdk-path }})"

    COMPLEMENT_CRYPTO_TEST_CLIENT_MATRIX=rr \
    COMPLEMENT_BASE_IMAGE={{ BASE_IMAGE }} \
    LIBRARY_PATH="${LIBRARY_PATH:-}:$(realpath {{ rust-sdk-path }}/target/{{ RUST_SDK_TARGET_DIR }})" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$(realpath {{ rust-sdk-path }}/target/{{ RUST_SDK_TARGET_DIR }})" \
    go test -v -count=1 -tags=rust -timeout 15m ./tests {{ if pattern != "" { "-run " + pattern } else { "" } }}

# Install the uniffi-bindgen-go command line utility, necessary to build the bindings.
install-uniffi-bindgen:
    cargo install uniffi-bindgen-go --rev 4f79e52bd8f518e5fa4d7acff9e586aee21e12a0 --git https://github.com/NordSecurity/uniffi-bindgen-go

# Rebuild the version of matrix-rust-sdk used and regenerate its Go bindings.
# The checkout path defaults to the COMPLEMENT_CRYPTO_RUST_SDK_DIR environment
# variable / .env entry (or pass it as an argument). This produces the
# internal/api/rust/matrix_sdk_ffi Go bindings plus
# <checkout>/target/<profile>/libmatrix_sdk_ffi.{a,so} that the tests link against.
# (requires on PATH: cargo, uniffi-bindgen-go)
rebuild-rust-sdk rust-sdk-path=env_var("COMPLEMENT_CRYPTO_RUST_SDK_DIR"):
    {{ just_executable() }} _build-rust-sdk {{ quote(rust-sdk-path) }} {{ quote(RUST_SDK_PROFILE) }} {{ quote(RUST_SDK_TARGET_DIR) }}
    {{ just_executable() }} _patch-ldflags
    ( cd {{ quote(COMPLEMENT_DIR) }} && \
        LIBRARY_PATH="{{ rust-sdk-path }}/target/{{ RUST_SDK_TARGET_DIR }}:${LIBRARY_PATH:-}" \
        go build -tags=rust ./internal/api/rust/... )

[private]
_build-rust-sdk dir profile target-dir:
    #!/usr/bin/env bash
    set -euxo pipefail
    cd "{{ dir }}"
    # Enable the min-rotation-period disable via matrix-sdk-ffi's own feature
    # flag rather than editing Cargo.toml: the previous sed injection was
    # brittle (depended on the exact `matrix-sdk-crypto = {` shape), left the
    # checkout dirty, and could silently no-op, so the tests could link a
    # library that still enforced the minimum rotation period.
    cargo build --profile {{ quote(profile) }} -p matrix-sdk-ffi \
        --features sentry,_only-for-testing-disable-megolm-minimum-rotation-period-ms
    uniffi-bindgen-go -o {{ quote(COMPLEMENT_DIR + "/internal/api/rust") }} --config {{ quote(COMPLEMENT_DIR + "/uniffi.toml") }} --library ./target/{{ target-dir }}/libmatrix_sdk_ffi.a
    # uniffi-bindgen-go releases that predate Uniffi 0.32 ignore the `go_mod`
    # setting in uniffi.toml and emit bare crate imports (e.g. "matrix_sdk"),
    # which do not resolve inside the Go module. Qualify them with the
    # configured module path. Idempotent: only the bare form is matched.
    go_mod="$(sed -nE 's/^go_mod[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' {{ quote(COMPLEMENT_DIR + "/uniffi.toml") }} | head -n1)"
    if [ -n "$go_mod" ]; then
        GO_MOD="$go_mod" find {{ quote(COMPLEMENT_DIR + "/internal/api/rust") }} -name '*.go' -exec \
            perl -pi -e 's#^([[:space:]]*)"(matrix_sdk[a-z_]*|ruma_events)"#\1"$ENV{GO_MOD}/\2"#' {} +
    fi


# Rebuild the version of matrix-js-sdk embedded in the JS bundle.
#
# The spec is either a remote `matrix-js-sdk@<url>#<sha>` or a local
# `matrix-js-sdk@file:/abs/path`. It defaults to the pinned GitLab fork
# (LOCAL_JS_SDK, above) and can be overridden by argument or environment.
#
# A remote spec is first materialised into a per-commit build cache
# (git fetch + `pnpm install --frozen-lockfile && pnpm build`). `yarn add <git
# url>` cannot build the package on its own: it has no lockfile, so it resolves
# newer vite/vitest types and fails `tsc`. A local `file:` path is used as-is
# and must be absolute, because yarn resolves `file:` against
# internal/api/js/js-sdk, differently at each nesting depth.
# (requires on PATH: git, pnpm, corepack)
rebuild-js-sdk js-sdk-version=LOCAL_JS_SDK:
    #!/usr/bin/env bash
    set -euo pipefail
    spec={{ quote(js-sdk-version) }}
    case "$spec" in
        *"@file:"*|file:*)
            dir="${spec#*file:}"
            if [ ! -f "$dir/lib/index.js" ]; then
                echo "error: '$dir' is not a built matrix-js-sdk checkout (no lib/index.js)" >&2
                exit 1
            fi
            ;;
        *)
            rest="${spec#matrix-js-sdk@}"
            url="${rest%%#*}"
            sha="${rest##*#}"
            if [[ "$url" = "$rest" && "$spec" =~ ^matrix-js-sdk@[0-9]+\.[0-9]+\.[0-9]+([-+].*)?$ ]]; then
                # Registry versions (for example matrix-js-sdk@29.1.0) are
                # supported by rebuild_js_sdk.sh and documented in README.md.
                ./rebuild_js_sdk.sh "$spec"
                exit 0
            elif [ "$url" = "$rest" ] || [ -z "$sha" ]; then
                echo "error: spec must be a registry version (matrix-js-sdk@X.Y.Z) or 'matrix-js-sdk@<url>#<sha>': $spec" >&2
                exit 1
            fi
            dir="${XDG_CACHE_HOME:-$HOME/.cache}/complement-crypto/matrix-js-sdk/$sha"
            if [ ! -f "$dir/lib/index.js" ]; then
                echo "materialising $url @ $sha into $dir"
                if [ ! -d "$dir/.git" ]; then
                    mkdir -p "$dir"
                    git -C "$dir" init -q
                    git -C "$dir" remote add origin "$url"
                fi
                git -C "$dir" fetch -q --depth 1 origin "$sha"
                git -C "$dir" checkout -q FETCH_HEAD
                (cd "$dir" && pnpm install --frozen-lockfile && pnpm build)
            fi
            ;;
    esac
    ./rebuild_js_sdk.sh "matrix-js-sdk@file:$dir"

# Generate every build artifact the test harness needs, from configurable
# sources. Safe to re-run: each artifact is only built when missing.
#
#   LOCAL_JS_SDK                    matrix-js-sdk spec (default: pinned GitLab fork)
#   COMPLEMENT_CRYPTO_RUST_SDK_DIR  matrix-rust-sdk checkout (Rust Go bindings)
#
# The Rust step is skipped when COMPLEMENT_CRYPTO_RUST_SDK_DIR is unset, since
# JS-only runs do not need it. Force a rebuild with the individual recipes
# (`just rebuild-js-sdk` / `just rebuild-rust-sdk`).
bootstrap:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f internal/api/js/chrome/dist/index.html ]; then
        echo "JS bundle already present (force with: just rebuild-js-sdk)"
    else
        "{{ just_executable() }}" rebuild-js-sdk
    fi
    if [ -z "${COMPLEMENT_CRYPTO_RUST_SDK_DIR:-}" ]; then
        echo "note: COMPLEMENT_CRYPTO_RUST_SDK_DIR unset; skipping Rust bindings (JS-only)."
    elif [ -f internal/api/rust/matrix_sdk_ffi/matrix_sdk_ffi.go ] && \
         [ -f "${COMPLEMENT_CRYPTO_RUST_SDK_DIR}/target/{{ RUST_SDK_TARGET_DIR }}/libmatrix_sdk_ffi.a" ]; then
        echo "Rust bindings already present (force with: just rebuild-rust-sdk)"
    else
        "{{ just_executable() }}" rebuild-rust-sdk
    fi

# Add the cgo LDFLAGS directive to the generated bindings (idempotent: the
# bindgen output is overwritten on every build, but a re-run over an existing
# file must not stack duplicate directives).
[private]
_patch-ldflags:
    #!/usr/bin/env bash
    set -euo pipefail
    f=internal/api/rust/matrix_sdk_ffi/matrix_sdk_ffi.go
    if grep -q '#cgo LDFLAGS: -lmatrix_sdk_ffi' "$f"; then
        exit 0
    fi
    perl -0pi.bak -e 's{// #include <matrix_sdk_ffi\.h>}{// #include <matrix_sdk_ffi.h>\n// #cgo LDFLAGS: -lmatrix_sdk_ffi}' "$f"
    rm -f "$f.bak"
