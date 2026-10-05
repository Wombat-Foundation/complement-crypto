package cc

import "testing"

func TestResolveNamespace(t *testing.T) {
	// unset => per-package default
	t.Setenv("COMPLEMENT_CRYPTO_NAMESPACE", "")
	if got := ResolveNamespace("rust"); got != "rust" {
		t.Fatalf("ResolveNamespace default = %q, want %q", got, "rust")
	}

	// acceptable values override the default, for every package
	for _, v := range []string{"crypto", "shard_01", "a.B-c9", "_", ".-"} {
		t.Setenv("COMPLEMENT_CRYPTO_NAMESPACE", v)
		if got := ResolveNamespace("rust"); got != v {
			t.Fatalf("ResolveNamespace(env=%q) = %q, want %q", v, got, v)
		}
	}

	// invalid values are rejected with a clear panic
	for _, v := range []string{"crypto name", "shard/01", "a:b", "ns$", "shard,2", "a=B"} {
		t.Setenv("COMPLEMENT_CRYPTO_NAMESPACE", v)
		func() {
			defer func() {
				want := "COMPLEMENT_CRYPTO_NAMESPACE must contain only characters in [A-Za-z0-9_.-], got: " + v
				if rec := recover(); rec != want {
					t.Fatalf("env=%q panic = %v, want %q", v, rec, want)
				}
			}()
			ResolveNamespace("crypto")
		}()
	}
}
