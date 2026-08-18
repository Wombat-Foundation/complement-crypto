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
				if rec := recover(); rec == nil {
					t.Fatalf("resolveNamespace(%q) did not panic", v)
				}
			}()
			resolveNamespace(v)
		}()
	}
}
