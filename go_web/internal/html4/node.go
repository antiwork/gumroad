// Package html4 reproduces what Rails::HTML4::SafeListSanitizer (rails-html-sanitizer 1.6.2 on
// Loofah 2.25.1 and Nokogiri 1.19.3, vendored libxml2 2.13.9) does around its scrubber: the
// HTML4 fragment parse and the to_html(encoding: "UTF-8") serialization of the result.
//
// ParseFragment builds the tree, the caller's scrubber mutates it, and RenderChildren on the
// fragment returns what sanitize would. ErrUnported means the input needs Rails.
package html4

// NodeType mirrors the libxml2 node types a parsed fragment can hold.
type NodeType uint8

const (
	FragmentNode NodeType = iota + 1
	ElementNode
	TextNode
	// CDATANode is the raw content of a script or style element (HTML_PRESERVE_NODE).
	CDATANode
	CommentNode
	ProcessingInstructionNode
)

// Attr is one attribute. Names are as parsed (ASCII-lowercased) and unique per element.
type Attr struct {
	Name  string
	Value string
	// Bare marks an attribute parsed without "=": it has no value node and serializes as a
	// bare name. Loofah reads its value as "".
	Bare bool
}

// Node is an element, text, CDATA, comment or processing instruction, or the fragment root.
type Node struct {
	Type NodeType
	// Name is the element name or the processing-instruction target.
	Name string
	// Data is the content of a text, CDATA, comment or processing-instruction node.
	Data  string
	Attrs []Attr
	// NoData marks a processing instruction without content (<?target>).
	NoData bool

	Parent, FirstChild, LastChild, PrevSibling, NextSibling *Node
}

// Children returns a snapshot of n's children, safe to range over while removing them.
func (n *Node) Children() []*Node {
	var out []*Node
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		out = append(out, c)
	}
	return out
}

// Remove unlinks n from its parent. Neighbouring text nodes are not merged, as with
// Nokogiri's Node#remove; serialization is unaffected.
func (n *Node) Remove() {
	p := n.Parent
	if p == nil {
		return
	}
	if n.PrevSibling != nil {
		n.PrevSibling.NextSibling = n.NextSibling
	} else {
		p.FirstChild = n.NextSibling
	}
	if n.NextSibling != nil {
		n.NextSibling.PrevSibling = n.PrevSibling
	} else {
		p.LastChild = n.PrevSibling
	}
	n.Parent, n.PrevSibling, n.NextSibling = nil, nil, nil
}

// Attr returns the value of the attribute named name.
func (n *Node) Attr(name string) (string, bool) {
	for _, a := range n.Attrs {
		if a.Name == name {
			return a.Value, true
		}
	}
	return "", false
}

// RemoveAttr removes the attribute named name, if present, in place: snapshot n.Attrs before
// ranging over it while removing.
func (n *Node) RemoveAttr(name string) {
	for i, a := range n.Attrs {
		if a.Name == name {
			last := len(n.Attrs) - 1
			copy(n.Attrs[i:], n.Attrs[i+1:])
			n.Attrs[last] = Attr{}
			n.Attrs = n.Attrs[:last]
			return
		}
	}
}

// SetAttr is node[name] = value (xmlSetProp): an existing attribute keeps its position,
// a new one is appended. Attr#value= serializes identically.
func (n *Node) SetAttr(name, value string) {
	for i := range n.Attrs {
		if n.Attrs[i].Name == name {
			n.Attrs[i] = Attr{Name: name, Value: value}
			return
		}
	}
	n.Attrs = append(n.Attrs, Attr{Name: name, Value: value})
}

func (n *Node) appendChild(c *Node) {
	c.Parent = n
	c.PrevSibling = n.LastChild
	if n.LastChild != nil {
		n.LastChild.NextSibling = c
	} else {
		n.FirstChild = c
	}
	n.LastChild = c
}
