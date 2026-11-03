package licenses

import (
	"database/sql"
	"slices"
)

// richContent is a rich_contents row; description is decoded on first use, since a titled
// page answers has_editor_content? without it.
type richContent struct {
	set     string // which branch of the query read it
	title   sql.NullString
	raw     []byte
	decoded bool
	nodes   any
}

// description is the JSON column. MySQL only stores valid JSON there.
func (c *richContent) description() any {
	if !c.decoded {
		c.decoded = true
		c.nodes, _ = decodeJSON(c.raw)
	}
	return c.nodes
}

var containerNodeTypes = []string{"orderedList", "bulletList", "listItem", "blockquote"}

// hasLicenseKey is RichContent#has_license_key?.
func (c *richContent) hasLicenseKey() bool {
	list, ok := c.description().([]any)
	return ok && slices.ContainsFunc(list, containsLicenseKeyNode)
}

func containsLicenseKeyNode(node any) bool {
	n, ok := node.(map[string]any)
	if !ok {
		return false
	}
	typ, _ := n["type"].(string)
	if typ == "licenseKey" {
		return true
	}
	children, ok := n["content"].([]any)
	return ok && slices.Contains(containerNodeTypes, typ) && slices.ContainsFunc(children, containsLicenseKeyNode)
}

// hasEditorContent is RichContent#has_editor_content?.
func (c *richContent) hasEditorContent() bool {
	if presentString(c.title) {
		return true
	}
	list, ok := c.description().([]any)
	return ok && slices.ContainsFunc(list, nodeHasContent)
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
