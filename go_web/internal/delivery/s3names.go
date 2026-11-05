package delivery

import (
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/antiwork/gumroad/go_web/internal/rails"
)

// s3Names is what S3Retrievable's has_s3_fields defines for a product file's url.
type s3Names struct {
	url string
	// baseURL is S3_BASE_URL, and ownerExternalID the external id of the user who owns the
	// file's product or post, "" when there is none.
	baseURL, ownerExternalID string
}

var guidNamespace = regexp.MustCompile(`\A[^/]+/[^/]+/[A-Za-z0-9]{32}/original/`)

func (n s3Names) s3() bool { return rails.Present(n.url) && strings.HasPrefix(n.url, n.baseURL) }

// filename is s3_filename: the name after the key's namespace, which can hold slashes.
func (n s3Names) filename() string {
	split := rails.Split(n.url, "/")
	relative := ""
	if strings.HasPrefix(n.url, n.baseURL) {
		relative = n.url[len(n.baseURL):]
	}
	namespaced := guidNamespace.MatchString(relative)
	if !namespaced && n.ownerExternalID != "" {
		parts := rails.Split(relative, "/")
		namespaced = len(parts) > 1 && parts[1] == n.ownerExternalID
	}
	start, max := 7, 8
	if namespaced {
		start, max = 8, 9
	}
	if len(split) > max {
		return strings.Join(split[start:], "/")
	}
	if len(split) == 0 {
		return ""
	}
	return split[len(split)-1]
}

// extension is s3_extension: File.extname of the url.
func (n s3Names) extension() string { return rails.FileExtname(n.url) }

// displayExtension is s3_display_extension. ok is false for a non-ASCII extension, whose
// String#upcase this port leaves to Ruby.
func (n s3Names) displayExtension() (string, bool) {
	e := n.extension()
	if e == "" {
		return "", true
	}
	for i := 0; i < len(e); i++ {
		if e[i] >= 0x80 {
			return "", false
		}
	}
	return strings.ToUpper(e[1:]), true
}

// displayName is s3_display_name: the filename less the extension's characters.
func (n s3Names) displayName() string {
	name, ext := n.filename(), n.extension()
	if ext == "" {
		return name
	}
	drop := utf8.RuneCountInString(ext)
	runes := []rune(name)
	if drop >= len(runes) {
		return ""
	}
	return string(runes[:len(runes)-drop])
}
