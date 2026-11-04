package credentials

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

type fixture struct {
	Key     string             `json:"key"`
	Lookups map[string]*string `json:"lookups"`
}

func loadFixture(t *testing.T) fixture {
	t.Helper()
	raw, err := os.ReadFile("testdata/credentials.json")
	if err != nil {
		t.Fatal(err)
	}
	var f fixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestLookupMatchesRailsCredentials(t *testing.T) {
	f := loadFixture(t)
	c, err := Load("testdata/test.yml.enc", f.Key)
	if err != nil {
		t.Fatal(err)
	}
	for name, want := range f.Lookups {
		got, ok := c.Lookup(name)
		switch {
		case want == nil && ok:
			t.Errorf("Lookup(%q) = %q, want absent", name, got)
		case want != nil && (!ok || got != *want):
			t.Errorf("Lookup(%q) = %q, %v; want %q", name, got, ok, *want)
		}
	}
}

func TestLoadRejectsAWrongKey(t *testing.T) {
	_, err := Load("testdata/test.yml.enc", strings.Repeat("ab", keyBytes))
	if err == nil || !strings.Contains(err.Error(), "does not decrypt") {
		t.Fatalf("err = %v", err)
	}
}

func TestLoadRejectsAMalformedKey(t *testing.T) {
	for _, key := range []string{"", "0123", strings.Repeat("zz", keyBytes)} {
		if _, err := Load("testdata/test.yml.enc", key); err == nil || !strings.Contains(err.Error(), "32 hex") {
			t.Errorf("key %q: err = %v", key, err)
		}
	}
}

func TestLoadRejectsATamperedFile(t *testing.T) {
	f := loadFixture(t)
	raw, err := os.ReadFile("testdata/test.yml.enc")
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(strings.TrimSpace(string(raw)), "--")
	flipped := []byte(parts[0])
	if flipped[0] == 'A' {
		flipped[0] = 'B'
	} else {
		flipped[0] = 'A'
	}
	for name, content := range map[string]string{
		"ciphertext": string(flipped) + "--" + parts[1] + "--" + parts[2],
		"no tag":     parts[0] + "--" + parts[1],
		"not base64": parts[0] + "--" + parts[1] + "--!!",
	} {
		path := filepath.Join(t.TempDir(), "tampered.yml.enc")
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(path, f.Key); err == nil {
			t.Errorf("%s: loaded", name)
		}
	}
}

func TestLoadNamesAMissingFile(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "absent.yml.enc"), loadFixture(t).Key); !os.IsNotExist(err) {
		t.Fatalf("err = %v", err)
	}
}

func TestMarshalStringReadsEveryLengthEncoding(t *testing.T) {
	raw, err := os.ReadFile("testdata/marshal_lengths.json")
	if err != nil {
		t.Fatal(err)
	}
	var prefixes map[string]string
	if err := json.Unmarshal(raw, &prefixes); err != nil {
		t.Fatal(err)
	}
	for length, prefixHex := range prefixes {
		n, _ := strconv.Atoi(length)
		prefix, err := hex.DecodeString(prefixHex)
		if err != nil {
			t.Fatal(err)
		}
		dumped := append(append(prefix, strings.Repeat("x", n)...), "\x06:\x06ET"...)
		got, err := marshalString(dumped)
		if err != nil || len(got) != n {
			t.Errorf("length %d: got %d bytes, %v", n, len(got), err)
		}
		if _, err := marshalString(dumped[:len(prefix)+n-1]); n > 0 && err == nil {
			t.Errorf("length %d: a truncated dump was read", n)
		}
	}
}

func TestMarshalStringRejectsOtherObjects(t *testing.T) {
	for name, dumped := range map[string]string{
		"empty":    "",
		"version":  "\x04\x07I\"\x06x\x06:\x06ET",
		"symbol":   "\x04\x08:\x06x",
		"negative": "\x04\x08\"\xff\x01",
	} {
		if _, err := marshalString([]byte(dumped)); err == nil {
			t.Errorf("%s: read", name)
		}
	}
}
