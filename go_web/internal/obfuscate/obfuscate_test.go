package obfuscate

import "testing"

// Vectors from ObfuscateIds with OBFUSCATE_IDS_CIPHER_KEY="test" and NUMERIC "1234".
var vectors = map[int64]string{
	1:             "fEGTaEpuKDsnDvf_MfecTA==",
	42:            "iqZUuCAuAbqt3aLadEozuA==",
	999999:        "pyNfQsCtXW60QywJUzrkqw==",
	1234567890123: "fzzthg92XM4Bp5qjSCvnWQ==",
}

func newIDs(t *testing.T) *IDs {
	t.Helper()
	ids, err := New("test", "1234")
	if err != nil {
		t.Fatal(err)
	}
	return ids
}

func TestEncryptAndDecryptMatchRuby(t *testing.T) {
	ids := newIDs(t)
	for id, external := range vectors {
		if got := ids.Encrypt(id); got != external {
			t.Errorf("Encrypt(%d) = %q, want %q", id, got, external)
		}
		if got, ok := ids.Decrypt(external); !ok || got != id {
			t.Errorf("Decrypt(%q) = %d, %v", external, got, ok)
		}
	}
}

func TestDecryptAcceptsWhatUrlsafeDecode64Accepts(t *testing.T) {
	ids := newIDs(t)
	for _, external := range []string{"fEGTaEpuKDsnDvf_MfecTA", "fEGTaEpuKDsnDvf/MfecTA=="} {
		if got, ok := ids.Decrypt(external); !ok || got != 1 {
			t.Errorf("Decrypt(%q) = %d, %v", external, got, ok)
		}
	}
	for _, external := range []string{"", "not-an-id", "fEGTaEpuKDsnDvf_MfecTA==\n", "AAAAAAAAAAAAAAAAAAAAAA=="} {
		if got, ok := ids.Decrypt(external); ok {
			t.Errorf("Decrypt(%q) = %d, want nil", external, got)
		}
	}
}

func TestNumericMatchesRuby(t *testing.T) {
	ids := newIDs(t)
	for id, encrypted := range map[int64]int64{1: 536871513, 42: 352322137, 12345678: 480349465} {
		if got, ok := ids.EncryptNumeric(id); !ok || got != encrypted {
			t.Errorf("EncryptNumeric(%d) = %d, want %d", id, got, encrypted)
		}
		if got := ids.DecryptNumeric(encrypted); got != id {
			t.Errorf("DecryptNumeric(%d) = %d, want %d", encrypted, got, id)
		}
	}
	if _, ok := ids.EncryptNumeric(1 << 30); ok {
		t.Error("EncryptNumeric must refuse ids Ruby refuses")
	}
}
