package store

import (
	"sync"
	"testing"

	"solvanta/backend/internal/domain"
)

// TestConcurrentReadersDuringDelete is the go test -race guard for the store's
// slice aliasing: every getter hands out the backing array AFTER releasing the
// read lock, exactly as Gin handlers consume it. deleteByID/removeMatch used to
// compact that same array in place (out := list[:0]) under the write lock, so a
// reader walking a snapshot overlapped the compaction with no happens-before
// edge between them. The helpers now allocate a fresh slice, which this test
// verifies stays race-free under concurrent readers.
func TestConcurrentReadersDuringDelete(t *testing.T) {
	m := New()

	// Snapshot the same way a handler does (alias, lock already released).
	seed := m.Questions()
	if len(seed) == 0 {
		t.Fatal("seed produced no questions")
	}
	ids := make([]domain.Question, len(seed))
	copy(ids, seed)

	readers, writers := sync.WaitGroup{}, sync.WaitGroup{}
	stop := make(chan struct{})

	// Readers: alias and walk the bank over and over.
	for g := 0; g < 4; g++ {
		readers.Add(1)
		go func() {
			defer readers.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				for _, q := range m.Questions() {
					_ = len(q.ID) + len(q.Stem) + len(q.CorrectAnswer)
				}
			}
		}()
	}

	// Writers: delete/restore on a rotating set of ids so deleteByID keeps
	// compacting the live backing array while the readers are walking it.
	for g := 0; g < 2; g++ {
		writers.Add(1)
		go func(g int) {
			defer writers.Done()
			for i := 0; i < 200; i++ {
				q := ids[(g*7+i)%len(ids)]
				m.DeleteQuestion(q.ID)
				m.SaveQuestion(q)
			}
		}(g)
	}

	writers.Wait()
	close(stop)
	readers.Wait()

	// Every delete above was paired with a restore, so the bank must be intact.
	after := m.Questions()
	if len(after) != len(seed) {
		t.Fatalf("question bank corrupted under concurrency: got %d, want %d", len(after), len(seed))
	}
}
