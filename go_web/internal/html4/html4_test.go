package html4

import (
	"bufio"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/testfiles"
)

// mutation mirrors the oracle scrubber in the fixture generator: a top-down Loofah traversal
// that removes elements (skipping their subtrees), removes attributes, sets attributes and
// removes comments.
type mutation struct {
	Remove         []string    `json:"remove"`
	RemoveAttrs    []string    `json:"remove_attrs"`
	Set            [][2]string `json:"set"`
	SetVia         string      `json:"set_via"`
	SetOnlyOn      string      `json:"set_only_on"`
	RemoveComments bool        `json:"remove_comments"`
}

type fixture struct {
	Kind     string    `json:"kind"`
	Input    string    `json:"input"`
	Mutation *mutation `json:"mutation"`
	Expected string    `json:"expected"`
}

func (m *mutation) apply(n *Node) {
	switch n.Type {
	case CommentNode:
		if m.RemoveComments {
			n.Remove()
			return
		}
	case ElementNode:
		for _, name := range m.Remove {
			if n.Name == name {
				n.Remove()
				return
			}
		}
		for _, name := range m.RemoveAttrs {
			n.RemoveAttr(name)
		}
		for _, kv := range m.Set {
			_, exists := n.Attr(kv[0])
			if m.SetVia == "attr" && exists || m.SetOnlyOn == "" || m.SetOnlyOn == n.Name {
				n.SetAttr(kv[0], kv[1])
			}
		}
	}
	for _, c := range n.Children() {
		m.apply(c)
	}
}

func sanitize(f fixture) (string, error) {
	if f.Input == "" {
		return "", nil
	}
	frag, err := ParseFragment(f.Input)
	if err != nil {
		return "", err
	}
	if f.Mutation != nil {
		for _, c := range frag.Children() {
			f.Mutation.apply(c)
		}
	}
	return frag.RenderChildren(), nil
}

func check(t *testing.T, cases []fixture) {
	t.Helper()
	native := map[string]int{}
	total := map[string]int{}
	for _, f := range cases {
		total[f.Kind]++
		got, err := sanitize(f)
		if errors.Is(err, ErrUnported) {
			continue
		}
		if err != nil {
			t.Fatalf("%q: %v", f.Input, err)
		}
		native[f.Kind]++
		if got != f.Expected {
			t.Errorf("%q (mutation %+v):\n got  %q\n want %q", f.Input, f.Mutation, got, f.Expected)
		}
	}
	for kind, n := range total {
		t.Logf("%s: %d/%d native", kind, native[kind], n)
	}
}

func TestFragmentsMatchRailsSanitizer(t *testing.T) {
	data, err := testfiles.Read("testdata/fragments.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	var cases []fixture
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	check(t, cases)
}

// HTML4_DIFF_FILE points at a JSON-lines file from the same generator, for large local runs.
func TestDifferentialFile(t *testing.T) {
	path := os.Getenv("HTML4_DIFF_FILE")
	if path == "" {
		t.Skip("HTML4_DIFF_FILE not set")
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	var cases []fixture
	sc := bufio.NewScanner(file)
	sc.Buffer(nil, 1<<26)
	for sc.Scan() {
		var f fixture
		if err := json.Unmarshal(sc.Bytes(), &f); err != nil {
			t.Fatal(err)
		}
		cases = append(cases, f)
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	check(t, cases)
}

func TestUnportedInputs(t *testing.T) {
	for _, in := range []string{
		"a\x00b", "caf\xe9", "\xed\xa0\x80", "<body>x", "x\n  <BODY>", "a</body><body>b",
		"<!DOCTYPE html>", "<?\xc3\xa9>", "<?x\xc3\xa9>", "<p xml:lang=en>a</p>", "<xml:p>a</xml:p>",
		strings.Repeat("<div>", maxDepth), strings.Repeat("x", maxInput+1),
	} {
		if _, err := ParseFragment(in); !errors.Is(err, ErrUnported) {
			t.Errorf("%q: got %v, want ErrUnported", in, err)
		}
	}
}

func TestMutationAPI(t *testing.T) {
	frag, err := ParseFragment(`<p class="a" id="b">x<!--c--><span>y</span>z</p>`)
	if err != nil {
		t.Fatal(err)
	}
	p := frag.FirstChild
	p.RemoveAttr("class")
	p.SetAttr("id", "q")
	p.SetAttr("title", `it's "x"`)
	for _, c := range p.Children() {
		if c.Type != TextNode {
			c.Remove()
		}
	}
	if got, want := frag.RenderChildren(), `<p id="q" title="it's &quot;x&quot;">xz</p>`; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func BenchmarkSanitize(b *testing.B) {
	var sb strings.Builder
	for sb.Len() < 5000 {
		sb.WriteString(`<p>Some <strong>bold</strong> text with a <a href="https://example.com/?a=1&amp;b=2" target="_blank" rel="noopener">link</a> &amp; caf&eacute; 😀</p><ul><li><p>item</p></li><li><p>two</p></li></ul>`)
	}
	in := sb.String()
	b.SetBytes(int64(len(in)))
	for b.Loop() {
		frag, err := ParseFragment(in)
		if err != nil {
			b.Fatal(err)
		}
		_ = frag.RenderChildren()
	}
}
