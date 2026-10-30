package domain

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// GradeBand is one row of a grading scale: a total of Min or more (up to the
// next band's Min) earns Grade, described by Remark.
type GradeBand struct {
	Min    float64 `json:"min"`
	Grade  string  `json:"grade"`
	Remark string  `json:"remark"`
}

// GradingScheme is how one range of classes is scored and graded: the split
// between continuous assessment and the end-of-term exam, the grade bands,
// and whether a best-N aggregate is printed.
type GradingScheme struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// ClassNames are class levels without the stream (JHS1, B4, KG2). Empty
	// on the default scheme, which covers every class no other scheme names.
	ClassNames  []string    `json:"classNames"`
	IsDefault   bool        `json:"isDefault"`
	ClassWeight float64     `json:"classWeight"`
	ExamWeight  float64     `json:"examWeight"`
	Bands       []GradeBand `json:"bands"`
	// Aggregate: the grades of CoreSubjects plus the best BestOthers other
	// subjects, summed (lower is better). Needs whole-number grades.
	ShowAggregate bool     `json:"showAggregate"`
	CoreSubjects  []string `json:"coreSubjects"`
	BestOthers    int      `json:"bestOthers"`
	// End of year, on the full-year average (the mean of the year's term
	// averages, each out of 100). Nil leaves that decision to the school.
	// PromoteAt: this or more is promoted. RepeatBelow: under this repeats
	// the class; in between is referred to the headteacher. InterventionBelow:
	// under this the parents are asked in, on any report from Term 2 on.
	PromoteAt         *float64 `json:"promoteAt,omitempty"`
	RepeatBelow       *float64 `json:"repeatBelow,omitempty"`
	InterventionBelow *float64 `json:"interventionBelow,omitempty"`
}

// GradingConfig is one school's grading set-up.
type GradingConfig struct {
	SchoolID  string          `json:"schoolId"`
	Schemes   []GradingScheme `json:"schemes"`
	UpdatedAt string          `json:"updatedAt,omitempty"`
	UpdatedBy string          `json:"updatedBy,omitempty"`
}

// DefaultGradingConfig is what a school grades with until its admin saves
// its own: the GES basic-school 30/70 split with the 1–9 scale and the
// BECE-style aggregate, for every class.
func DefaultGradingConfig(schoolID string) GradingConfig {
	return GradingConfig{
		SchoolID: schoolID,
		Schemes: []GradingScheme{{
			ID:          "default",
			Name:        "GES basic school",
			IsDefault:   true,
			ClassNames:  []string{},
			ClassWeight: 30,
			ExamWeight:  70,
			Bands: []GradeBand{
				{80, "1", "Highest"}, {70, "2", "Higher"}, {60, "3", "High"},
				{55, "4", "High Average"}, {50, "5", "Average"},
				{45, "6", "Low Average"}, {40, "7", "Low"}, {35, "8", "Lower"},
				{0, "9", "Lowest"},
			},
			ShowAggregate: true,
			CoreSubjects:  []string{"ENG", "MATH", "SCI", "SOC"},
			BestOthers:    2,
		}},
	}
}

// Limits keep a config small and printable.
const (
	maxSchemes      = 20
	maxBands        = 15
	maxNameLen      = 60
	maxGradeLen     = 4
	maxRemarkLen    = 24
	maxClassNameLen = 20
)

// Normalize trims text, upper-cases class names and sorts bands highest
// first, then reports the first rule the config breaks (nil when valid).
func (g *GradingConfig) Normalize() error {
	if len(g.Schemes) == 0 {
		return fmt.Errorf("add at least one grading scheme")
	}
	if len(g.Schemes) > maxSchemes {
		return fmt.Errorf("at most %d grading schemes", maxSchemes)
	}
	defaults := 0
	owner := map[string]string{}
	ids := map[string]bool{}
	for i := range g.Schemes {
		s := &g.Schemes[i]
		s.ID = strings.TrimSpace(s.ID)
		s.Name = strings.TrimSpace(s.Name)
		if s.ID == "" || len(s.ID) > maxNameLen || ids[s.ID] {
			return fmt.Errorf("scheme %d needs a unique id", i+1)
		}
		ids[s.ID] = true
		if s.Name == "" || len(s.Name) > maxNameLen {
			return fmt.Errorf("scheme %d needs a name (up to %d characters)", i+1, maxNameLen)
		}
		if s.IsDefault {
			defaults++
		}
		names := []string{}
		for _, n := range s.ClassNames {
			n = strings.ToUpper(strings.TrimSpace(n))
			if n == "" {
				continue
			}
			if len(n) > maxClassNameLen {
				return fmt.Errorf("%s: class %q is too long", s.Name, n)
			}
			if other, taken := owner[n]; taken {
				return fmt.Errorf("%s is in both %q and %q; a class can follow only one scheme", n, other, s.Name)
			}
			owner[n] = s.Name
			names = append(names, n)
		}
		s.ClassNames = names
		if !s.IsDefault && len(names) == 0 {
			return fmt.Errorf("%s: choose the classes it applies to", s.Name)
		}
		if s.ClassWeight < 0 || s.ExamWeight < 0 || s.ClassWeight+s.ExamWeight != 100 {
			return fmt.Errorf("%s: class score and exam must add up to 100%%", s.Name)
		}
		if len(s.Bands) == 0 || len(s.Bands) > maxBands {
			return fmt.Errorf("%s: between 1 and %d grade bands", s.Name, maxBands)
		}
		sort.SliceStable(s.Bands, func(a, b int) bool { return s.Bands[a].Min > s.Bands[b].Min })
		for j := range s.Bands {
			b := &s.Bands[j]
			b.Grade = strings.TrimSpace(b.Grade)
			b.Remark = strings.TrimSpace(b.Remark)
			if b.Min < 0 || b.Min > 100 {
				return fmt.Errorf("%s: band minimums must be between 0 and 100", s.Name)
			}
			if j > 0 && b.Min == s.Bands[j-1].Min {
				return fmt.Errorf("%s: two bands start at %g", s.Name, b.Min)
			}
			if b.Grade == "" || len(b.Grade) > maxGradeLen {
				return fmt.Errorf("%s: every band needs a grade (up to %d characters)", s.Name, maxGradeLen)
			}
			if len(b.Remark) > maxRemarkLen {
				return fmt.Errorf("%s: remark %q is too long", s.Name, b.Remark)
			}
		}
		if s.Bands[len(s.Bands)-1].Min != 0 {
			return fmt.Errorf("%s: the lowest band must start at 0", s.Name)
		}
		if s.ShowAggregate {
			for _, b := range s.Bands {
				if _, err := strconv.Atoi(b.Grade); err != nil {
					return fmt.Errorf("%s: an aggregate needs whole-number grades (1, 2, 3…)", s.Name)
				}
			}
			if s.BestOthers < 0 || s.BestOthers > 20 {
				return fmt.Errorf("%s: best-of count must be 0–20", s.Name)
			}
		}
		for _, t := range []*float64{s.PromoteAt, s.RepeatBelow, s.InterventionBelow} {
			if t != nil && (*t < 0 || *t > 100) {
				return fmt.Errorf("%s: year-average thresholds must be between 0 and 100", s.Name)
			}
		}
		if s.PromoteAt != nil && s.RepeatBelow != nil && *s.RepeatBelow > *s.PromoteAt {
			return fmt.Errorf("%s: the repeat mark can't be above the promotion mark", s.Name)
		}
		if s.CoreSubjects == nil {
			s.CoreSubjects = []string{}
		}
	}
	if defaults != 1 {
		return fmt.Errorf("exactly one scheme must be the default for unlisted classes")
	}
	return nil
}

// FinishedTerm is a term the school has moved on from, kept with the grading
// set-up in force when it ended so its results are always read the way they
// were awarded — transcripts and the year chart on every device.
type FinishedTerm struct {
	SchoolTerm
	Grading GradingConfig `json:"grading"`
}
