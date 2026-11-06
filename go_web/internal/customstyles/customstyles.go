// Package customstyles renders SellerProfile#custom_styles: the storefront theme blob from
// app/views/layouts/custom_styles/styles.scss.erb, as SassC compiles it.
package customstyles

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"
)

// ErrUnported means Rails has to render these styles.
var ErrUnported = errors.New("customstyles: styles this port leaves to Rails")

// Profile holds the seller_profiles columns custom_styles reads; nil is NULL.
type Profile struct {
	HighlightColor, BackgroundColor, Font, BorderRadius, ButtonHover *string
}

const defaultFont = "ABC Favorit"

var (
	fontChoices         = []string{"ABC Favorit", "Inter", "Domine", "Merriweather", "Roboto Slab", "Roboto Mono"}
	dangerColorChoices  = []string{"#dc341e", "#9b1c12", "#ffb4ab"}
	borderRadiusChoices = map[string]string{"none": "0rem", "small": "0.25rem", "medium": "0.5rem", "large": "1rem"}
	buttonHoverOffsets  = map[string]string{"lift": "0.25rem", "none": "0rem"}
)

// CSS is custom_styles without its cache: "" for a profile that fails
// custom_style_attributes_safe?.
func CSS(p Profile) (string, error) {
	// SellerProfile's after_initialize defaults, which use ||= and so leave "" alone.
	highlight := valueOr(p.HighlightColor, "#ff90e8")
	background := valueOr(p.BackgroundColor, "#ffffff")
	font := valueOr(p.Font, defaultFont)
	radius := valueOr(p.BorderRadius, "small")
	hover := valueOr(p.ButtonHover, "lift")

	// custom_style_attributes_safe?, in its && order: safe_for_css?'s regexp raises on invalid
	// UTF-8, which only Rails can answer.
	for _, color := range [...]string{highlight, background} {
		if !utf8.ValidString(color) {
			return "", ErrUnported
		}
		if !safeForCSS(color) {
			return "", nil
		}
	}
	radiusCSS, radiusOK := borderRadiusChoices[radius]
	hoverCSS, hoverOK := buttonHoverOffsets[hover]
	if !slices.Contains(fontChoices, font) || !radiusOK || !hoverOK {
		return "", nil
	}

	var j judge
	backgroundRGB := parseHex(background)
	accent, onAccent := j.accessibleAccent(parseHex(highlight))
	onBackground := j.contrastFor(backgroundRGB)
	onPrimary := j.contrastFor(parseHex(onBackground))
	danger := onBackground
	for _, color := range dangerColorChoices {
		if j.ge(ratioBetween(parseHex(color), backgroundRGB), wcagAANormalText) {
			danger = color
			break
		}
	}
	onDanger := j.contrastFor(parseHex(danger))
	if j.unsure {
		return "", ErrUnported
	}

	family := fontFamily(font)
	var b strings.Builder
	if font != defaultFont {
		// FONT_CHOICES are letters and spaces, so spaces are all Addressable::URI.encode touches.
		fmt.Fprintf(&b, "@import url(https://fonts.googleapis.com/css2?family=%s:wght@400;600&display=swap);", strings.ReplaceAll(font, " ", "%20"))
	}
	// Custom properties keep their raw text after the colon; libsass emits the hex and font
	// declarations in body verbatim as static values.
	fmt.Fprintf(&b, ":root{--accent: %s;--accent-with-text: %s;--contrast-accent: %s;--font-family: %s;--color: %s;--primary: var(--color);--contrast-primary: %s;--filled: %s;--contrast-filled: var(--color);--danger: %s;--contrast-danger: %s;--body-bg: %s;--active-bg: rgb(var(--color) / var(--gray-1));--border-alpha: 1;--radius: %s;--button-hover-offset: %s}",
		splitColor(parseHex(highlight)), splitColor(accent), splitHex(onAccent), family, splitHex(onBackground),
		splitHex(onPrimary), splitColor(backgroundRGB), splitHex(danger), splitHex(onDanger), background, radiusCSS, hoverCSS)
	fmt.Fprintf(&b, "body{background-color:%s;color:%s;font-family:%s}\n", background, onBackground, family)
	return b.String(), nil
}

// WrapperBackground is custom_html_wrapper_theme_background_css's color: background_color
// with its default, "" unless safe_for_css?.
func WrapperBackground(p Profile) (string, error) {
	color := valueOr(p.BackgroundColor, "#ffffff")
	if !utf8.ValidString(color) {
		return "", ErrUnported
	}
	if !safeForCSS(color) {
		return "", nil
	}
	return color, nil
}

func valueOr(s *string, fallback string) string {
	if s == nil {
		return fallback
	}
	return *s
}

// safeForCSS is HexColorValidator.safe_for_css?: #rgb or #rrggbb in either case.
func safeForCSS(s string) bool {
	if (len(s) != 4 && len(s) != 7) || s[0] != '#' {
		return false
	}
	for i := 1; i < len(s); i++ {
		if c := s[i] | 0x20; !(s[i] >= '0' && s[i] <= '9') && !(c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func fontFamily(font string) string {
	fallback := "sans-serif"
	switch font {
	case "Domine", "Merriweather", "Roboto Slab":
		fallback = "serif"
	case "Roboto Mono":
		fallback = "monospace"
	}
	return `"` + font + `", "` + defaultFont + `", ` + fallback
}

// splitColor is the template's split-color: red, green, and blue as a space list.
func splitColor(c rgb) string { return fmt.Sprintf("%d %d %d", c[0], c[1], c[2]) }

func splitHex(s string) string { return splitColor(parseHex(s)) }
