// Package credentials reads config/credentials/<env>.yml.enc as Rails.application.credentials
// does, so a secret Rails keeps there needs no second copy for go_web.
package credentials

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"strings"

	"go.yaml.in/yaml/v3"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// ActiveSupport::EncryptedFile's CIPHER is aes-128-gcm.
const keyBytes = 16

type Credentials struct {
	root *yaml.Node
}

// Load decrypts path with masterKey, RAILS_MASTER_KEY's hex.
func Load(path, masterKey string) (*Credentials, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	plain, err := decrypt(strings.TrimSpace(string(content)), masterKey)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(plain, &doc); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	c := &Credentials{}
	if len(doc.Content) > 0 {
		c.root = resolve(doc.Content[0])
	}
	return c, nil
}

// Lookup is GlobalConfig's credentials fallback: name.downcase.split("__") is the dig path.
// Null and a missing key are both absent, as dig's nil is. A scalar is returned as written,
// which is Ruby's value for a string; Psych would type a plain 0123, 0x1f or yes instead.
func (c *Credentials) Lookup(name string) (string, bool) {
	if c == nil {
		return "", false
	}
	node := c.root
	for key := range strings.SplitSeq(strings.ToLower(name), "__") {
		node = child(node, key)
	}
	if node == nil || node.Kind != yaml.ScalarNode || node.ShortTag() == "!!null" {
		return "", false
	}
	return node.Value, true
}

func child(mapping *yaml.Node, key string) *yaml.Node {
	if mapping == nil || mapping.Kind != yaml.MappingNode {
		return nil
	}
	// Psych's revive_hash: entries apply in order, so the last of a repeated key wins and a
	// merge (<<) overrides the keys above it; in a merged list, the first mapping wins.
	var found *yaml.Node
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		k, v := mapping.Content[i], resolve(mapping.Content[i+1])
		switch {
		case k.ShortTag() == "!!merge":
			sources := []*yaml.Node{v}
			if v.Kind == yaml.SequenceNode {
				sources = v.Content
			}
			for _, source := range sources {
				if merged := child(resolve(source), key); merged != nil {
					found = merged
					break
				}
			}
		case k.Value == key:
			found = v
		}
	}
	return found
}

func resolve(node *yaml.Node) *yaml.Node {
	for node != nil && node.Kind == yaml.AliasNode {
		node = node.Alias
	}
	return node
}

// decrypt is MessageEncryptor#decrypt_and_verify for EncryptedFile's encryptor, whose
// plaintext is Marshal.dump of the YAML.
func decrypt(message, masterKey string) ([]byte, error) {
	key, err := hex.DecodeString(masterKey)
	if err != nil || len(key) != keyBytes {
		return nil, errors.New("RAILS_MASTER_KEY must be 32 hex characters")
	}
	sealed, iv, ok := rails.SplitEncryptedMessage(message)
	if !ok {
		return nil, errors.New("not an encrypted credentials file")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	dumped, err := gcm.Open(nil, iv, sealed, nil)
	if err != nil {
		return nil, errors.New("RAILS_MASTER_KEY does not decrypt it")
	}
	return marshalString(dumped)
}

// marshalString reads Marshal.dump of a String: version 4.8, 'I' when instance variables (the
// encoding) follow, '"', then the length and bytes.
func marshalString(b []byte) ([]byte, error) {
	malformed := errors.New("credentials are not a Marshal-dumped String")
	if len(b) < 3 || b[0] != 4 || b[1] != 8 {
		return nil, malformed
	}
	i := 2
	if b[i] == 'I' {
		i++
	}
	if i >= len(b) || b[i] != '"' {
		return nil, malformed
	}
	n, i, ok := marshalLength(b, i+1)
	if !ok || n > len(b)-i {
		return nil, malformed
	}
	return b[i : i+n], nil
}

// marshalLength is Marshal's w_long for a non-negative value: 0, then n+5 in one byte below
// 123, else a byte count of 1-4 and that many little-endian bytes.
func marshalLength(b []byte, i int) (n, next int, ok bool) {
	if i >= len(b) {
		return 0, 0, false
	}
	c := int8(b[i])
	i++
	switch {
	case c == 0:
		return 0, i, true
	case c > 4:
		return int(c) - 5, i, true
	case c < 0:
		return 0, 0, false
	}
	size := int(c)
	if size > len(b)-i {
		return 0, 0, false
	}
	for k := range size {
		n |= int(b[i+k]) << (8 * k)
	}
	return n, i + size, true
}
