package tests

import "testing"

func TestResolveNamespace(t *testing.T) {
	// acceptable values pass through unchanged
	valid := []string{"crypto", "shard_01", "a.B-c9", "_", ".-"}
	for _, v := range valid {
		if got := resolveNamespace(v); got != v {
			t.Fatalf("resolveNamespace(%q) = %q, want %q", v, got, v)
		}
	}

	// empty defaults to "crypto"
	if got := resolveNamespace(""); got != "crypto" {
		t.Fatalf("resolveNamespace(\"\") = %q, want %q", got, "crypto")
	}

	// invalid values are rejected with a clear panic
	invalid := []string{"crypto name", "shard/01", "a:b", "ns$", "shard,2", "a=B"}
	for _, v := range invalid {
		func() {
			defer func() {
				rec := recover()
				if rec == nil {
					t.Fatalf("resolveNamespace(%q) did not panic", v)
				}
				want := "COMPLEMENT_CRYPTO_NAMESPACE must contain only characters in [A-Za-z0-9_.-], got: " + v
				if rec != want {
					t.Fatalf("resolveNamespace(%q) panic = %q, want %q", v, rec, want)
				}
			}()
			resolveNamespace(v)
		}()
	}
}
