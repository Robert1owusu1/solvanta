package domain

import "testing"

// chain builds a hash-chained log the way the store does.
func chain(entries []AuditEntry) []AuditEntry {
	prev := ""
	out := make([]AuditEntry, len(entries))
	for i, e := range entries {
		e.Hash = AuditChainHash(prev, e)
		prev = e.Hash
		out[i] = e
	}
	return out
}

func TestAuditChainVerifies(t *testing.T) {
	log := chain([]AuditEntry{
		{Action: "auth.login", Actor: "Admin", Target: "USR-1", Timestamp: "2026-11-01 09:00"},
		{Action: "student.create", Actor: "Admin", Target: "STU-9", Timestamp: "2026-11-01 09:05"},
		{Action: "score.manual", Actor: "Teacher", Target: "SUB-3", Timestamp: "2026-11-01 09:10"},
	})
	if ok, at := VerifyAuditChain(log); !ok {
		t.Fatalf("a well-formed chain should verify, broke at %d", at)
	}
}

func TestAuditChainDetectsTampering(t *testing.T) {
	log := chain([]AuditEntry{
		{Action: "auth.login", Actor: "Admin", Timestamp: "t1"},
		{Action: "fees.record", Actor: "Bursar", Detail: "GHS 500", Timestamp: "t2"},
		{Action: "auth.logout", Actor: "Admin", Timestamp: "t3"},
	})
	// Someone edits a recorded amount without recomputing the chain.
	log[1].Detail = "GHS 50"
	ok, at := VerifyAuditChain(log)
	if ok || at != 1 {
		t.Errorf("tampering at index 1 should be detected, got ok=%v at=%d", ok, at)
	}

	// Dropping an entry also breaks the chain.
	good := chain([]AuditEntry{
		{Action: "a", Timestamp: "1"}, {Action: "b", Timestamp: "2"}, {Action: "c", Timestamp: "3"},
	})
	dropped := []AuditEntry{good[0], good[2]}
	if ok, _ := VerifyAuditChain(dropped); ok {
		t.Error("dropping the middle entry should break the chain")
	}
}
