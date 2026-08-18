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
	// The namespace prefixes every docker network/container this suite deploys
	// (e.g. `complement_<namespace>.<blueprint>.hs1`). It must be unique per
	// `go test` process so concurrent sharded runs get fully isolated
	// homeservers instead of colliding on the same name. Defaults to `crypto`
	// for a single (unsharded) run.
	namespace := os.Getenv("COMPLEMENT_CRYPTO_NAMESPACE")
	if namespace == "" {
		namespace = "crypto"
	}
	instance.TestMain(m, namespace)

}

// Instance returns the test instance. Guaranteed to be non-nil if called in a test,
// because TestMain would have been called before the test runs.
func Instance() *cc.Instance {
	return instance
}
