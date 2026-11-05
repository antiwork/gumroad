package licenses

import (
	"slices"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
)

// richContent is a rich_contents row and the branch of the query that read it.
type richContent struct {
	set string
	delivery.RichContent
}

var containerNodeTypes = []string{"orderedList", "bulletList", "listItem", "blockquote"}

// hasLicenseKey is RichContent#has_license_key?.
func (c *richContent) hasLicenseKey() bool {
	list, ok := c.Description().([]any)
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

// hasEditorContent is RichContent#has_editor_content?, false for a description Ruby would raise on.
func (c *richContent) hasEditorContent() bool {
	has, _ := c.HasEditorContent()
	return has
}
