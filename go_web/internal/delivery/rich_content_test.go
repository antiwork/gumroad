package delivery

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
)

const testCipherKey = "test"

func testIDs(t testing.TB) *obfuscate.IDs {
	t.Helper()
	ids, err := obfuscate.New(testCipherKey, "1234")
	if err != nil {
		t.Fatal(err)
	}
	return ids
}

// encryptPlaintext is ObfuscateIds.encrypt for any string, which ids.Encrypt only takes as an id.
func encryptPlaintext(plain string) string {
	key := sha256.Sum256([]byte(testCipherKey))
	block, _ := aes.NewCipher(key[:])
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	data := append([]byte(plain), bytes.Repeat([]byte{byte(pad)}, pad)...)
	out := make([]byte, len(data))
	cipher.NewCBCEncrypter(block, make([]byte, aes.BlockSize)).CryptBlocks(out, data)
	return base64.URLEncoding.EncodeToString(out)
}

// embeds expands {1}, {2}... into the external ids of 1, 2... and {abc} into the ciphertext of "abc".
func embeds(ids *obfuscate.IDs, description string) string {
	for i := int64(1); i <= 9; i++ {
		description = strings.ReplaceAll(description, fmt.Sprintf("{%d}", i), ids.Encrypt(i))
	}
	return strings.ReplaceAll(description, "{abc}", encryptPlaintext("abc"))
}

func TestEncryptPlaintextIsObfuscateIDs(t *testing.T) {
	if got, want := encryptPlaintext("42"), testIDs(t).Encrypt(42); got != want {
		t.Fatalf("encryptPlaintext(42) = %q, want %q", got, want)
	}
}

// Expectations checked against RichContent#embedded_product_file_ids_in_order with the same key.
func TestEmbeddedProductFileIDsInOrder(t *testing.T) {
	ids := testIDs(t)
	for _, tc := range []struct {
		description string
		want        []int64
		wantErr     bool
	}{
		{description: `[]`},
		{description: `null`},
		{description: `{}`},
		{description: `"fileEmbed"`},
		{description: `[{"type":"fileEmbed","attrs":{"id":"{1}"}},
			{"type":"fileEmbedGroup","content":[{"type":"fileEmbed","attrs":{"id":"{2}"}},{"type":"fileEmbed","attrs":{"id":"{1}"}}]},
			{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"fileEmbed","attrs":{"id":"{3}"}}]}]},
			{"type":"orderedList","content":[{"type":"blockquote","content":[{"type":"fileEmbed","attrs":{"id":"{4}"}}]}]}]`,
			want: []int64{1, 2, 3, 4}},
		// Ids decrypt returns nil for, and present values that never decrypt.
		{description: `[{"type":"fileEmbed","attrs":{"id":"not-an-id"}},{"type":"fileEmbed","attrs":{"id":""}},
			{"type":"fileEmbed","attrs":{"id":"   "}},{"type":"fileEmbed","attrs":{"id":42}},{"type":"fileEmbed","attrs":{"id":true}},
			{"type":"fileEmbed","attrs":{"id":null}},{"type":"fileEmbed","attrs":{}},{"type":"fileEmbed"},
			{"type":"fileEmbed","attrs":null},{"type":"fileEmbed","attrs":{"id":["{1}"]}},{"type":"fileEmbed","attrs":{"id":{"a":"{1}"}}},
			{"type":"fileEmbed","attrs":{"id":" {1}"}},{"type":"fileEmbed","attrs":{"id":"{1}\n"}},{"type":"fileEmbed","attrs":{"id":1.5}}]`},
		// A plaintext that is not a number decrypts to 0, which still counts as an embed.
		{description: `[{"type":"fileEmbed","attrs":{"id":"{abc}"}}]`, want: []int64{0}},
		// Only file embed containers are walked, and only when they mention fileEmbed.
		{description: `[{"type":"paragraph","content":[{"type":"fileEmbed","attrs":{"id":"{1}"}}]}]`},
		{description: `[{"type":"blockquote","content":[null,5,[1]]}]`},
		{description: `[{"type":"blockquote","content":[{"fileEmbed":1}]}]`},
		{description: `[{"type":5},{"type":null},{"content":[{"type":"fileEmbed","attrs":{"id":"{1}"}}]},"a type string"]`},
		{description: `[{"type":"FileEmbed","attrs":{"id":"{1}"}},{"type":"fileEmbed ","attrs":{"id":"{2}"}}]`},
		{description: `[{"type":"listItem","content":"no embeds here"}]`},
		// Where Ruby raises.
		{description: `{"type":"fileEmbed"}`, wantErr: true},
		{description: `5`, wantErr: true},
		{description: `true`, wantErr: true},
		{description: `false`, wantErr: true},
		{description: `[null]`, wantErr: true},
		{description: `[5]`, wantErr: true},
		{description: `[[]]`, wantErr: true},
		{description: `[false]`, wantErr: true},
		{description: `[{"type":"fileEmbed","attrs":"{1}"}]`, wantErr: true},
		{description: `[{"type":"fileEmbed","attrs":["{1}"]}]`, wantErr: true},
		{description: `[{"type":"fileEmbed","attrs":5}]`, wantErr: true},
		{description: `[{"type":"blockquote","content":[{"fileEmbed":1},5]}]`, wantErr: true},
		{description: `[{"type":"listItem","content":"a fileEmbed"}]`, wantErr: true},
		{description: `[{"type":"fileEmbedGroup","content":{"type":"fileEmbed"}}]`, wantErr: true},
		{description: `[{"type":"fileEmbedGroup","content":[{"type":"fileEmbed","attrs":{"id":"{1}"}},null]}]`, wantErr: true},
	} {
		c := &RichContent{DescriptionJSON: []byte(embeds(ids, tc.description))}
		got, err := c.embeddedProductFileIDsInOrder(ids)
		if (err != nil) != tc.wantErr || !slices.Equal(got, tc.want) {
			t.Errorf("%s: got %v, %v; want %v, error %v", tc.description, got, err, tc.want, tc.wantErr)
		}
	}
}

// Expectations checked against RichContent#has_editor_content?.
func TestHasEditorContent(t *testing.T) {
	for _, tc := range []struct {
		title       any
		description string
		want        bool
		wantErr     bool
	}{
		{title: "Intro", description: `[]`, want: true},
		{title: "Intro", description: `"raises without the title"`, want: true},
		{title: "  ", description: `[{"type":"paragraph"}]`},
		{description: `[{"type":"paragraph"},{"type":"heading","content":[]}]`},
		{description: `[{"type":"paragraph","content":[{"type":"text","text":"Hi"}]}]`, want: true},
		// A whitespace text node is still a leaf other than a paragraph or heading.
		{description: `[{"type":"paragraph","content":[{"type":"text","text":"  "}]}]`, want: true},
		{description: `[{"type":"image"}]`, want: true},
		{description: `[{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph"}]}]}]`},
		{description: `[{"text":5}]`, want: true},
		{description: `[{"type":"paragraph","text":false}]`},
		{description: `[null,5,"x",[]]`},
		{description: `[]`},
		{description: `{}`},
		{description: `{"type":"image"}`},
		{description: `null`},
		{description: `""`},
		{description: `"   "`},
		{description: `false`},
		{description: `"x"`, wantErr: true},
		{description: `5`, wantErr: true},
		{description: `true`, wantErr: true},
	} {
		c := &RichContent{DescriptionJSON: []byte(tc.description)}
		if title, ok := tc.title.(string); ok {
			c.Title = sql.NullString{String: title, Valid: true}
		}
		got, err := c.HasEditorContent()
		if got != tc.want || (err != nil) != tc.wantErr {
			t.Errorf("%v %s: got %v, %v; want %v, error %v", tc.title, tc.description, got, err, tc.want, tc.wantErr)
		}
	}
}
