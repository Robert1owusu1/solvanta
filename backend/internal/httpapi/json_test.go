package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

// TestNilSlicesMarshallAsEmptyArrays locks the parity guarantee that list
// endpoints always emit [] (never null) so Dart clients decode cleanly.
func TestNilSlicesMarshallAsEmptyArrays(t *testing.T) {
	r := newTestServer(t, Config{})

	for _, path := range []string{
		"/api/notifications/unread",
		"/api/gate/events",
		"/api/announcements",
		"/api/audit",
	} {
		token := login(t, r, "admin@solvanta.app", "admin123")
		rec := do(r, http.MethodGet, path, "", map[string]string{"Authorization": "Bearer " + token})
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: status %d", path, rec.Code)
		}
		body := rec.Body.Bytes()
		if string(body) == "null" {
			t.Fatalf("%s: nil slice serialized as null", path)
		}
		var arr []json.RawMessage
		if err := json.Unmarshal(body, &arr); err != nil {
			t.Fatalf("%s: body not a JSON array: %v", path, err)
		}
	}
}

func TestNonNilListsLeavesDataIntact(t *testing.T) {
	got := nonNilLists([]int{1, 2})
	if s, ok := got.([]int); !ok || len(s) != 2 {
		t.Fatalf("non-Nil slice mangled: %#v", got)
	}
	if m, ok := nonNilLists(map[string]int{"a": 1}).(map[string]int); !ok || m["a"] != 1 {
		t.Fatalf("non-slice value mangled: %#v", got)
	}
	n := nonNilLists([]string(nil)).([]string)
	if n == nil || len(n) != 0 {
		t.Fatalf("nil slice not converted to empty: %#v (nil=%v)", n, n == nil)
	}
}
