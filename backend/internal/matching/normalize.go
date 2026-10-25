package matching

import (
	"math/big"
	"regexp"
	"strings"
	"unicode"
)

// symbolReplacer maps the many ways a symbol reaches us — handwriting OCR,
// phone keyboards, copy-paste from a document — onto one plain form.
var symbolReplacer = strings.NewReplacer(
	"−", "-", // minus sign
	"–", "-", // en dash
	"—", "-", // em dash
	"⁄", "/", // fraction slash
	"∕", "/", // division slash
	"÷", "/", // ÷
	"×", "*", // ×
	"·", "*", // middle dot
	" ", " ", // no-break space
	"½", "1/2", "¼", "1/4", "¾", "3/4",
	"⅓", "1/3", "⅔", "2/3", "⅛", "1/8",
	"‘", "'", "’", "'", "“", `"`, "”", `"`,
)

var (
	spaces         = regexp.MustCompile(`\s+`)
	aroundOperator = regexp.MustCompile(`\s*([/*+=^()<>-])\s*`)
	// A space between a whole number and a fraction ("1 1/2") is meaningful;
	// aroundOperator would not touch it, but it would glue "1 / 2" → "1/2".
	nonWord = regexp.MustCompile(`[^\p{L}\p{N}\s]+`)
)

// normalize brings an answer to a canonical spelling WITHOUT losing what it
// says. Case, spacing, symbol variants and a trailing full stop are ignored;
// decimal points, slashes and minus signs are kept, because "1/2", "12" and
// "1.2" are different answers.
func normalize(s string) string {
	s = symbolReplacer.Replace(s)
	s = strings.ToLower(strings.TrimSpace(s))
	s = spaces.ReplaceAllString(s, " ")
	s = strings.Trim(s, `"'`)
	s = strings.TrimRight(s, ".,;:! ")
	s = aroundOperator.ReplaceAllString(s, "$1")
	return strings.TrimSpace(s)
}

// wordsOnly is the comparison for answers made of words alone ("True",
// "photosynthesis", "Kojo ran, but he was late."): punctuation carries no
// meaning there, so it is dropped. It is never used when a digit is present.
func wordsOnly(s string) string {
	s = nonWord.ReplaceAllString(normalize(s), " ")
	return strings.TrimSpace(spaces.ReplaceAllString(s, " "))
}

func hasDigit(s string) bool {
	return strings.IndexFunc(s, unicode.IsDigit) >= 0
}

// form is how a number was written. Two answers with the same value but a
// different form ("1/2" and "0.5", or "2/4" and "1/2") are only flagged as
// equivalent, never awarded silently: a question may be asking for the form.
type form int

const (
	formDecimal  form = iota // 5, 0.75, .5, 1,000
	formFraction             // 3/4
	formMixed                // 1 1/2
	formPercent              // 75%
)

func (f form) String() string {
	switch f {
	case formFraction:
		return "fraction"
	case formMixed:
		return "mixed number"
	case formPercent:
		return "percentage"
	}
	return "decimal"
}

// number is a parsed numeric answer.
type number struct {
	value    *big.Rat
	form     form
	text     string // the numeric part as written, normalized
	unit     string // trailing unit or leading currency, normalized ("" if none)
	decimals int    // digits after the decimal point (decimal form only)
}

var (
	currencyPrefix = regexp.MustCompile(`^(gh₵|ghc|ghs|gh¢|₵|¢|\$|£|€)\s*`)
	numberPart     = regexp.MustCompile(`^(-?(?:\d{1,3}(?:,\d{3})+|\d+)?(?:\.\d+)?(?: \d+/\d+|/\d+)?%?)\s*(.*)$`)
	unitPart       = regexp.MustCompile(`^[\p{L}µ°²³/]+$`)
	mixedNumber    = regexp.MustCompile(`^(-?)(\d+) (\d+)/(\d+)$`)
	fraction       = regexp.MustCompile(`^-?\d+/\d+$`)
	decimal        = regexp.MustCompile(`^-?(?:\d{1,3}(?:,\d{3})+|\d+)?(?:\.(\d+))?$`)
)

// parseNumber reads a normalized answer as a number with an optional unit.
// It reports false for anything that is not plainly one number — an
// expression, a word answer, two numbers — so those are compared as text.
func parseNumber(s string) (number, bool) {
	var n number
	if m := currencyPrefix.FindStringSubmatch(s); m != nil {
		n.unit = "ghs"
		if m[1] == "$" || m[1] == "£" || m[1] == "€" {
			n.unit = m[1]
		}
		s = s[len(m[0]):]
	}
	m := numberPart.FindStringSubmatch(s)
	if m == nil || m[1] == "" || m[1] == "-" {
		return number{}, false
	}
	num, rest := m[1], strings.TrimSpace(m[2])
	if rest != "" {
		if n.unit != "" || !unitPart.MatchString(rest) {
			return number{}, false
		}
		n.unit = rest
	}
	n.text = num

	percent := strings.HasSuffix(num, "%")
	num = strings.TrimSuffix(num, "%")
	r := new(big.Rat)
	switch {
	case mixedNumber.MatchString(num):
		p := mixedNumber.FindStringSubmatch(num)
		whole, ok1 := new(big.Rat).SetString(p[2])
		frac, ok2 := new(big.Rat).SetString(p[3] + "/" + p[4])
		if !ok1 || !ok2 || p[4] == "0" {
			return number{}, false
		}
		r.Add(whole, frac)
		if p[1] == "-" {
			r.Neg(r)
		}
		n.form = formMixed
	case fraction.MatchString(num):
		if strings.HasSuffix(num, "/0") {
			return number{}, false
		}
		if _, ok := r.SetString(num); !ok {
			return number{}, false
		}
		n.form = formFraction
	case decimal.MatchString(num):
		d := decimal.FindStringSubmatch(num)
		if _, ok := r.SetString(strings.ReplaceAll(num, ",", "")); !ok {
			return number{}, false
		}
		n.form, n.decimals = formDecimal, len(d[1])
	default:
		return number{}, false
	}
	if percent {
		if n.form != formDecimal {
			return number{}, false
		}
		r.Quo(r, big.NewRat(100, 1))
		n.form = formPercent
	}
	n.value = r
	return n, true
}

// sameWriting reports whether two equal numbers are also written the same
// way: same form, and for fractions the same numerator and denominator.
// "0.50" and "0.5" are the same writing; "2/4" and "1/2" are not.
func sameWriting(a, b number) bool {
	if a.form != b.form {
		return false
	}
	if a.form == formFraction || a.form == formMixed {
		return strings.TrimPrefix(a.text, "+") == strings.TrimPrefix(b.text, "+")
	}
	return true
}

// roundsTo reports whether the more precise decimal, rounded to the other's
// decimal places, equals it — "0.33" for 1/3, or "0.333" against "0.33". Only
// for answers given to at least one decimal place: rounding 2.5 to "3" is a
// different answer, not a rounding.
func roundsTo(student, accepted number) (int, bool) {
	coarse := student
	fine := accepted
	if student.form == formDecimal && accepted.form == formDecimal && accepted.decimals < student.decimals {
		coarse, fine = accepted, student
	}
	if coarse.form != formDecimal || coarse.decimals < 1 {
		return 0, false
	}
	return coarse.decimals, fine.value.FloatString(coarse.decimals) == coarse.value.FloatString(coarse.decimals)
}

// lossyKey reproduces the scheme editor's normalizeAnswer: lowercase with
// every non-alphanumeric removed. The editor stores misconception patterns
// only in this form ("3/4" is saved as "34"), so it is the one way to compare
// against them — and because it cannot tell "3/4" from "34", a match made
// only at this level is always flagged.
func lossyKey(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		}
	}
	return b.String()
}
