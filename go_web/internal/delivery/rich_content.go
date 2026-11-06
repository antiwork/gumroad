package delivery

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// RichContent is a rich_contents row. The description is decoded on first use, since a titled
// page answers has_editor_content? without it.
type RichContent struct {
	id              int64
	Title           sql.NullString
	DescriptionJSON []byte
	updatedAt       time.Time
	position        int64
	decoded         bool
	nodes           any
}

// Description is the decoded column. Type::Json reads JSON it cannot parse as nil, and MySQL
// stores none.
func (c *RichContent) Description() any {
	if !c.decoded {
		c.decoded = true
		c.nodes, _ = decodeJSON(c.DescriptionJSON)
	}
	return c.nodes
}

// HasEditorContent is RichContent#has_editor_content?. The error is where Ruby raises: a
// description that is a non-blank String, a number or true has no #any?.
func (c *RichContent) HasEditorContent() (bool, error) {
	if c.Title.Valid && rails.Present(c.Title.String) {
		return true, nil
	}
	switch d := c.Description().(type) {
	case []any:
		return slices.ContainsFunc(d, nodeHasContent), nil
	case map[string]any:
		// Hash#any? yields [key, value] pairs, which node_has_content? rejects.
		return false, nil
	default:
		if !jsonPresent(d) {
			return false, nil
		}
		return false, fmt.Errorf("delivery: a %T rich content description has no #any?", d)
	}
}

func nodeHasContent(node any) bool {
	n, ok := node.(map[string]any)
	if !ok {
		return false
	}
	if jsonPresent(n["text"]) {
		return true
	}
	if children, ok := n["content"].([]any); ok {
		return slices.ContainsFunc(children, nodeHasContent)
	}
	typ, _ := n["type"].(string)
	return typ != "paragraph" && typ != "heading"
}

const fileEmbedNodeType = "fileEmbed"

// RichContent::FILE_EMBED_CONTAINER_NODE_TYPES.
var fileEmbedContainerNodeTypes = []string{"fileEmbedGroup", "orderedList", "bulletList", "listItem", "blockquote"}

// embeddedProductFileIDsInOrder is RichContent#embedded_product_file_ids_in_order. The error is
// where select_file_embed_ids raises on a node that is not a Hash.
func (c *RichContent) embeddedProductFileIDsInOrder(ids *obfuscate.IDs) ([]int64, error) {
	var out []int64
	var err error
	switch d := c.Description().(type) {
	case nil:
	case []any:
		for _, node := range d {
			if out, err = appendFileEmbedIDs(out, node, ids); err != nil {
				return nil, err
			}
		}
	case map[string]any:
		// Array(hash) is its [key, value] pairs, and Array#[] takes no "type".
		if len(d) > 0 {
			return nil, fmt.Errorf("delivery: a Hash rich content description has no file embed nodes")
		}
	case string:
		// Array(string) is [string], and String#[] never finds a fileEmbed type.
	default:
		return nil, fmt.Errorf("delivery: a %T rich content description has no file embed nodes", d)
	}
	return uniq(out), nil
}

// appendFileEmbedIDs is select_file_embed_ids, flattened as flat_map and compact leave it.
func appendFileEmbedIDs(out []int64, node any, ids *obfuscate.IDs) ([]int64, error) {
	switch n := node.(type) {
	case string:
		// String#[]("type") is "type" or nil, neither of which matches below.
		return out, nil
	case map[string]any:
		typ, _ := n["type"].(string)
		if typ == fileEmbedNodeType {
			var id any
			switch attrs := n["attrs"].(type) {
			case nil:
			case map[string]any:
				id = attrs["id"]
			default:
				return nil, fmt.Errorf("delivery: a fileEmbed's %T attrs has no #dig", attrs)
			}
			// Any other present id's to_s (a number, true, an inspected Array or Hash) is never
			// base64 of whole cipher blocks, so ObfuscateIds.decrypt returns nil for it.
			// Decrypt's ok is also false for a plaintext beyond int64, which Ruby would keep as
			// a Bignum that matches no row; only the cipher key's holder can produce one.
			if s, ok := id.(string); ok && rails.Present(s) {
				if decrypted, ok := ids.Decrypt(s); ok {
					out = append(out, decrypted)
				}
			}
			return out, nil
		}
		if !slices.Contains(fileEmbedContainerNodeTypes, typ) || !inspectIncludes(n["content"], fileEmbedNodeType) {
			return out, nil
		}
		children, ok := n["content"].([]any)
		if !ok {
			// A String has no #flat_map, and a Hash's yields [key, value] pairs.
			return nil, fmt.Errorf("delivery: a %s's %T content has no file embed nodes", typ, n["content"])
		}
		var err error
		for _, child := range children {
			if out, err = appendFileEmbedIDs(out, child, ids); err != nil {
				return nil, err
			}
		}
		return out, nil
	}
	// nil, true and false have no #[]; Integer#[] and Array#[] take no String.
	return nil, fmt.Errorf("delivery: a %T rich content node has no type", node)
}

// inspectIncludes is v.to_s.include?(sub) for a decoded JSON value. Inspect quotes every key
// and string without touching ASCII letters, so it holds sub exactly when one of them does.
func inspectIncludes(v any, sub string) bool {
	switch v := v.(type) {
	case string:
		return strings.Contains(v, sub)
	case []any:
		return slices.ContainsFunc(v, func(item any) bool { return inspectIncludes(item, sub) })
	case map[string]any:
		for k, item := range v {
			if strings.Contains(k, sub) || inspectIncludes(item, sub) {
				return true
			}
		}
	}
	return false
}

func uniq(ids []int64) []int64 {
	seen := make(map[int64]bool, len(ids))
	out := ids[:0]
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}

// jsonPresent is Object#present? for a decoded JSON value.
func jsonPresent(v any) bool {
	switch v := v.(type) {
	case nil:
		return false
	case bool:
		return v
	case string:
		return rails.Present(v)
	case []any:
		return len(v) > 0
	case map[string]any:
		return len(v) > 0
	}
	return true
}

func decodeJSON(data []byte) (any, error) {
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil, nil
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.UseNumber()
	var v any
	err := decoder.Decode(&v)
	return v, err
}

// EmbeddedProductFileIDs is RichContent#embedded_product_file_ids_in_order for a description
// column's JSON.
func EmbeddedProductFileIDs(descriptionJSON []byte, ids *obfuscate.IDs) ([]int64, error) {
	return (&RichContent{DescriptionJSON: descriptionJSON}).embeddedProductFileIDsInOrder(ids)
}
