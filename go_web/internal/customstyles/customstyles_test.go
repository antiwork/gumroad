package customstyles

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

// fixtureCase is one profile through SellerProfile#custom_styles, from the generator that loads
// the app's own model, ContrastColor, HexColorValidator, and template under SassC. Random cases
// carry the SHA-256 of the CSS instead of the CSS itself.
type fixtureCase struct {
	Kind    string             `json:"kind"`
	Profile map[string]*string `json:"profile"`
	CSS     *string            `json:"css"`
	SHA256  string             `json:"sha256"`
}

func (fc fixtureCase) profile() Profile {
	return Profile{
		HighlightColor:  fc.Profile["highlight_color"],
		BackgroundColor: fc.Profile["background_color"],
		Font:            fc.Profile["font"],
		BorderRadius:    fc.Profile["border_radius"],
		ButtonHover:     fc.Profile["button_hover"],
	}
}

// check reports whether CSS answered natively, failing on any difference from Ruby.
func check(t *testing.T, fc fixtureCase) bool {
	t.Helper()
	got, err := CSS(fc.profile())
	if errors.Is(err, ErrUnported) {
		return false
	}
	if err != nil {
		t.Fatalf("%v: %v", fc.Profile, err)
	}
	switch {
	case fc.CSS != nil:
		if got != *fc.CSS {
			t.Errorf("%s\n got %q\nwant %q", describe(fc.Profile), got, *fc.CSS)
		}
	default:
		if sum := sha256.Sum256([]byte(got)); hex.EncodeToString(sum[:]) != fc.SHA256 {
			t.Errorf("%s: got %q, which does not hash to %s", describe(fc.Profile), got, fc.SHA256)
		}
	}
	return true
}

func describe(profile map[string]*string) string {
	out := map[string]any{}
	for k, v := range profile {
		if v == nil {
			out[k] = nil
		} else {
			out[k] = *v
		}
	}
	b, _ := json.Marshal(out)
	return string(b)
}

type fixtureFile struct {
	Sources map[string]string `json:"sources"`
	Cases   []fixtureCase     `json:"cases"`
}

func loadFixtures(t *testing.T) fixtureFile {
	t.Helper()
	data, err := testfiles.Read("testdata/styles.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	var f fixtureFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestFixtures(t *testing.T) {
	f := loadFixtures(t)
	counts := map[string]int{}
	for _, fc := range f.Cases {
		counts[fc.Kind]++
		// Every color in this domain clears the tie tolerance, so a fallback here is a regression.
		if !check(t, fc) {
			t.Errorf("%s: ErrUnported", describe(fc.Profile))
		}
	}
	if counts["hand"] == 0 || counts["random"] == 0 {
		t.Fatalf("fixture kinds: %v", counts)
	}
}

// The fixtures were generated from these files; an edit to any of them needs a port review.
func TestPinnedRailsSources(t *testing.T) {
	sources := loadFixtures(t).Sources
	if len(sources) == 0 {
		t.Fatal("no pinned sources")
	}
	for path, want := range sources {
		data, err := os.ReadFile("../../../" + path)
		if os.IsNotExist(err) {
			t.Skip("not running inside the Rails checkout")
		}
		if err != nil {
			t.Fatal(err)
		}
		if sum := sha256.Sum256(data); hex.EncodeToString(sum[:]) != want {
			t.Errorf("%s changed since testdata/styles.json.gz was generated", path)
		}
	}
}

// Ruby raises only where safe_for_css? reaches an invalid color; elsewhere the value is just
// not a choice.
func TestInvalidUTF8(t *testing.T) {
	bad, red := "#ff\xff", "red"
	for _, tc := range []struct {
		name    string
		profile Profile
		unport  bool
	}{
		{"highlight", Profile{HighlightColor: &bad}, true},
		{"background", Profile{BackgroundColor: &bad}, true},
		{"background after an unsafe highlight", Profile{HighlightColor: &red, BackgroundColor: &bad}, false},
		{"font", Profile{Font: &bad}, false},
		{"border radius", Profile{BorderRadius: &bad}, false},
		{"button hover", Profile{ButtonHover: &bad}, false},
	} {
		got, err := CSS(tc.profile)
		if tc.unport && !errors.Is(err, ErrUnported) {
			t.Errorf("%s: err = %v, want ErrUnported", tc.name, err)
		}
		if !tc.unport && (got != "" || err != nil) {
			t.Errorf("%s: got %q, %v; want \"\"", tc.name, got, err)
		}
	}
}

func TestTieGuard(t *testing.T) {
	var j judge
	if j.ge(4.5+1e-12, wcagAANormalText); !j.unsure {
		t.Fatal("a comparison within tieTolerance did not mark the judge unsure")
	}
	j = judge{}
	if j.ge(4.5001, wcagAANormalText); j.unsure {
		t.Fatal("a clear comparison marked the judge unsure")
	}
}

// CUSTOMSTYLES_DIFF_FILE points at JSON lines from the generator's diff mode, for large local runs.
func TestDifferentialFile(t *testing.T) {
	path := os.Getenv("CUSTOMSTYLES_DIFF_FILE")
	if path == "" {
		t.Skip("CUSTOMSTYLES_DIFF_FILE not set")
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	native, total := 0, 0
	scanner := bufio.NewScanner(file)
	scanner.Buffer(nil, 1<<20)
	for scanner.Scan() {
		var fc fixtureCase
		if err := json.Unmarshal(scanner.Bytes(), &fc); err != nil {
			t.Fatal(err)
		}
		total++
		if check(t, fc) {
			native++
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	t.Logf("%d/%d native", native, total)
}

// CUSTOMSTYLES_COLORS_DIR holds the generator's colors-mode dump: accessible_accent,
// text_color_on_background, and danger_color for every #rrggbb.
func TestEveryColor(t *testing.T) {
	dir := os.Getenv("CUSTOMSTYLES_COLORS_DIR")
	if dir == "" {
		t.Skip("CUSTOMSTYLES_COLORS_DIR not set")
	}
	highlight, err := os.ReadFile(filepath.Join(dir, "highlight.bin"))
	if err != nil {
		t.Fatal(err)
	}
	background, err := os.ReadFile(filepath.Join(dir, "background.bin"))
	if err != nil {
		t.Fatal(err)
	}
	const n = 1 << 24
	if len(highlight) != 4*n || len(background) != n {
		t.Fatalf("dump sizes %d, %d", len(highlight), len(background))
	}

	var mu sync.Mutex
	var unsure, mismatches int
	var wg sync.WaitGroup
	workers := runtime.NumCPU()
	for w := range workers {
		wg.Go(func() {
			localUnsure, localMismatches := 0, 0
			for i := w * n / workers; i < (w+1)*n/workers; i++ {
				c := rgb{i >> 16, i >> 8 & 0xff, i & 0xff}

				var j judge
				accent, text := j.accessibleAccent(c)
				want := highlight[4*i : 4*i+4]
				wantText := black
				if want[3] == 1 {
					wantText = white
				}
				accentOK := accent == rgb{int(want[0]), int(want[1]), int(want[2])} && text == wantText

				onBackground := j.contrastFor(c)
				danger := 3
				for k, color := range dangerColorChoices {
					if j.ge(ratioBetween(parseHex(color), c), wcagAANormalText) {
						danger = k
						break
					}
				}
				got := byte(danger << 1)
				if onBackground == white {
					got |= 1
				}

				if j.unsure {
					localUnsure++
				}
				if !accentOK || got != background[i] {
					localMismatches++
					if localMismatches <= 5 {
						t.Errorf("#%06x: accent %s %s (want % x), background bits %d (want %d), unsure %v",
							i, toHex(accent), text, want, got, background[i], j.unsure)
					}
				}
			}
			mu.Lock()
			unsure += localUnsure
			mismatches += localMismatches
			mu.Unlock()
		})
	}
	wg.Wait()
	t.Logf("%d colors: %d mismatches, %d within the tie tolerance", n, mismatches, unsure)
}
