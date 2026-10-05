# Build and run complement-crypto tests

set dotenv-load

BASE_IMAGE := "ghcr.io/matrix-org/synapse-service:v1.117.0"
COMPLEMENT_DIR := justfile_directory()

# Default `yarn add` target for the `rebuild-js-sdk` recipe, pointing at a local
# matrix-js-sdk checkout. Note that `file:` paths are resolved by yarn relative to
# internal/api/js/js-sdk (where `yarn add` runs), not relative to this justfile --
# hence the long ../../../../../ prefix. Override per-invocation with an argument,
# or machine-wide via the LOCAL_JS_SDK environment variable / .env entry.
LOCAL_JS_SDK := env_var_or_default("LOCAL_JS_SDK", "matrix-js-sdk@file:../../../../../matrix-js-sdk")

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
    LIBRARY_PATH="${LIBRARY_PATH:-}:$(realpath {{ rust-sdk-path }}/target/debug)" \
    LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}:$(realpath {{ rust-sdk-path }}/target/debug)" \
    go test -v -count=1 -tags=rust -timeout 15m ./tests {{ if pattern != "" { "-run " + pattern } else { "" } }}

# Install the uniffi-bindgen-go command line utility, necessary to build the bindings.
install-uniffi-bindgen:
    cargo install uniffi-bindgen-go --rev 4f79e52bd8f518e5fa4d7acff9e586aee21e12a0 --git https://github.com/NordSecurity/uniffi-bindgen-go

# Rebuild the version of matrix-rust-sdk used and regenerate its Go bindings.
rebuild-rust-sdk rust-sdk-path:
    {{ just_executable() }} _build-rust-sdk {{ quote(rust-sdk-path) }}
    {{ just_executable() }} _patch-ldflags

[private]
_build-rust-sdk dir:
    #!/usr/bin/env bash
    set -euxo pipefail

    cd "{{ dir }}"

    # The `_disable-minimum-rotation-period-ms` feature lives on matrix-sdk-crypto,
    # not on matrix-sdk-ffi, so it cannot be passed via `--features` here. Patch the
    # workspace Cargo.toml to inject it into the crypto dep (mirroring upstream
    # rebuild_rust_sdk.sh), and restore both files afterwards.
    cp Cargo.toml Cargo.toml.backup
    cp Cargo.lock Cargo.lock.backup
    trap 'mv -f Cargo.toml.backup Cargo.toml; mv -f Cargo.lock.backup Cargo.lock' EXIT
    sed -i.bak 's#matrix-sdk-crypto = {#matrix-sdk-crypto = {features = ["_disable-minimum-rotation-period-ms"],#' Cargo.toml
    rm -f Cargo.toml.bak
    if ! grep -Eq '^[[:space:]]*matrix-sdk-crypto[[:space:]]*=[[:space:]]*\{[^}]*_disable-minimum-rotation-period-ms' Cargo.toml; then
        echo "Failed to inject _disable-minimum-rotation-period-ms feature" >&2
        exit 1
    fi
    cargo build -p matrix-sdk-ffi --features 'sentry'
    uniffi-bindgen-go -o {{ COMPLEMENT_DIR }}/internal/api/rust --config {{ COMPLEMENT_DIR }}/uniffi.toml --library ./target/debug/libmatrix_sdk_ffi.a

# Rebuild the version of matrix-js-sdk used. The version is fed to `yarn add`, e.g. `matrix-js-sdk@file:/path/to/checkout`. (requires on PATH: corepack)
rebuild-js-sdk js-sdk-version=LOCAL_JS_SDK:
    ./rebuild_js_sdk.sh {{ quote(js-sdk-version) }}

# Add the cgo LDFLAGS directive to the generated bindings.
[private]
_patch-ldflags:
    sed -i.bak 's^// #include <matrix_sdk_ffi.h>^// #include <matrix_sdk_ffi.h>\n// #cgo LDFLAGS: -lmatrix_sdk_ffi^' internal/api/rust/matrix_sdk_ffi/matrix_sdk_ffi.go
