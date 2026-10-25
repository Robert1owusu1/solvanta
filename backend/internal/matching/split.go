package matching

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

var (
	// questionMarker starts a question's block: "1.", "2)", "3:", "Q5",
	// "Q.6", "Question 7:". The full stop or colon must be followed by a
	// space or the end of the line, so "0.5" and "3.5 cm" stay answers. A
	// bare number is NOT a marker — "1 1/2" is a mixed number, and "4 - 3"
	// is working.
	questionMarker = regexp.MustCompile(`(?i)^\s*(?:(?:q|qn|qu|question)\s*\.?\s*(\d{1,3})(?:\s*[.):\-])?(?:\s|$)|(\d{1,3})\s*(?:\)|[.:](?:\s|$)))\s*(.*)$`)
	// answerLabel marks the final answer inside a block: "Ans: 11/12",
	// "Answer = 0.5".
	answerLabel = regexp.MustCompile(`(?i)^\s*(?:ans|answer)\s*[:=.\-]?\s*(.*)$`)
)

// SplitAnswers divides a confirmed page reading into answers per question.
//
// Each question starts at a marker line ("1.", "Q2", "Question 3:"). In a
// question's block the final answer is the line labelled "Ans"/"Answer", or
// failing that the last line — and if that line is a calculation ending in
// "= x", the x. Every other line is kept as working. How each answer was
// found is recorded in its Notes, so the teacher can see it.
//
// Text before the first marker is returned as unassigned rather than guessed
// into a question. A page with no markers at all is all unassigned, except
// that singleQuestion > 0 assigns it whole to that question (a one-question
// scheme), with a note saying so.
func SplitAnswers(text string, singleQuestion int) ([]Answer, []string) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")

	type block struct {
		number int
		lines  []string
	}
	var blocks []block
	var unassigned []string
	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if m := questionMarker.FindStringSubmatch(line); m != nil {
			n, _ := strconv.Atoi(firstNonEmpty(m[1], m[2]))
			b := block{number: n}
			if rest := strings.TrimSpace(m[3]); rest != "" {
				b.lines = append(b.lines, rest)
			}
			blocks = append(blocks, b)
			continue
		}
		if len(blocks) == 0 {
			unassigned = append(unassigned, line)
			continue
		}
		last := &blocks[len(blocks)-1]
		last.lines = append(last.lines, line)
	}

	if len(blocks) == 0 && singleQuestion > 0 && len(unassigned) > 0 {
		a := finalAnswer(singleQuestion, unassigned)
		a.Notes = append([]string{"No question numbers were found on the page; the whole reading was treated as this question's answer."}, a.Notes...)
		return []Answer{a}, nil
	}

	answers := make([]Answer, 0, len(blocks))
	for _, b := range blocks {
		answers = append(answers, finalAnswer(b.number, b.lines))
	}
	return answers, unassigned
}

// finalAnswer picks a block's final answer and keeps the rest as working.
func finalAnswer(number int, lines []string) Answer {
	a := Answer{QuestionNumber: number}
	if len(lines) == 0 {
		return a
	}
	for i := len(lines) - 1; i >= 0; i-- {
		if m := answerLabel.FindStringSubmatch(lines[i]); m != nil && strings.TrimSpace(m[1]) != "" {
			a.Text = strings.TrimSpace(m[1])
			a.Working = append(append([]string(nil), lines[:i]...), lines[i+1:]...)
			return a
		}
	}
	last := lines[len(lines)-1]
	a.Working = append([]string(nil), lines[:len(lines)-1]...)
	if i := strings.LastIndex(last, "="); i >= 0 && strings.TrimSpace(last[i+1:]) != "" {
		a.Text = strings.TrimSpace(last[i+1:])
		if strings.TrimSpace(last[:i]) != "" {
			a.Working = append(a.Working, last)
			a.Notes = append(a.Notes, fmt.Sprintf("Final answer taken from the end of %q.", last))
		}
		return a
	}
	a.Text = last
	if len(lines) > 1 {
		a.Notes = append(a.Notes, "No line was labelled as the answer, so the last line was used.")
	}
	return a
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
