package kube

import "testing"

func TestSelectExternalIPReturnsExternalIPAmongMixedAddresses(t *testing.T) {
	addresses := []NodeAddress{
		{Type: "InternalIP", Address: "10.0.0.2"},
		{Type: "Hostname", Address: "node-1"},
		{Type: "ExternalIP", Address: "203.0.113.10"},
	}

	got, err := SelectExternalIP(addresses)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "203.0.113.10" {
		t.Fatalf("SelectExternalIP() = %q, want %q", got, "203.0.113.10")
	}
}

func TestSelectExternalIPErrorsWhenNoExternalIPPresent(t *testing.T) {
	addresses := []NodeAddress{
		{Type: "InternalIP", Address: "10.0.0.2"},
		{Type: "Hostname", Address: "node-1"},
	}

	if _, err := SelectExternalIP(addresses); err == nil {
		t.Fatal("expected an error when no ExternalIP is present, got nil")
	}
}
