package tests

import (
	"os"
	"testing"

	"github.com/matrix-org/complement-crypto/internal/cc"
	"github.com/matrix-org/complement-crypto/internal/config"
)

// globals to ensure we are always referring to the same set of HSes/proxies between tests
var (
	instance *cc.Instance
)

// Main entry point when users run `go test`. Defined in https://pkg.go.dev/testing#hdr-Main
func TestMain(m *testing.M) {
	instance = cc.NewInstance(config.NewComplementCryptoConfigFromEnvVars("./mitmproxy_addons"))
	namespace := resolveNamespace(os.Getenv("COMPLEMENT_CRYPTO_NAMESPACE"))
	instance.TestMain(m, namespace)

}

// resolveNamespace returns the namespace applied to every Docker network/container
// this suite deploys (e.g. `complement_<namespace>.<blueprint>.hs1`). It must be
// unique per `go test` process so concurrent sharded runs get fully isolated
// homeservers instead of colliding on the same name. Defaults to `crypto` for a
// single (unsharded) run. An empty value (or the default) is fine, but any value
// containing characters outside [A-Za-z0-9_.-] would produce invalid Docker names
// and fail with a low-level Docker error, so we reject it here with a clear message.
func resolveNamespace(raw string) string {
	if raw == "" {
		raw = "crypto"
	}
	for _, r := range raw {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '.' || r == '-') {
			panic("COMPLEMENT_CRYPTO_NAMESPACE must contain only characters in [A-Za-z0-9_.-], got: " + raw)
		}
	}
	return raw
}

// Instance returns the test instance. Guaranteed to be non-nil if called in a test,
// because TestMain would have been called before the test runs.
func Instance() *cc.Instance {
	return instance
}
