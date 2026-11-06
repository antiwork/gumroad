package customstyles

import (
	"fmt"
	"math"
)

// ContrastColor from lib/utilities/contrast_color.rb, ported operation by operation. Products
// are wrapped in float64() so Go cannot fuse them into FMAs that Ruby never performs.

const (
	white = "#ffffff"
	black = "#000000"

	wcagAANormalText = 4.5
	apcaTieBand      = 10.0

	// Ruby's ** is the C library's pow and Go's math.Pow is not, so the two can disagree in the
	// last bits. Every comparison of a pow-derived value closer than this goes to Rails instead.
	tieTolerance = 1e-9
)

type rgb [3]int

var whiteRGB, blackRGB = rgb{255, 255, 255}, rgb{0, 0, 0}

// judge carries whether any comparison landed within tieTolerance.
type judge struct{ unsure bool }

func (j *judge) near(a, b float64) {
	if math.Abs(a-b) < tieTolerance {
		j.unsure = true
	}
}

func (j *judge) gt(a, b float64) bool { j.near(a, b); return a > b }
func (j *judge) ge(a, b float64) bool { j.near(a, b); return a >= b }
func (j *judge) lt(a, b float64) bool { j.near(a, b); return a < b }
func (j *judge) le(a, b float64) bool { j.near(a, b); return a <= b }

// parseHex is ContrastColor.parse for values that already passed safeForCSS, so there is
// nothing to trim and no failure case.
func parseHex(s string) rgb {
	if len(s) == 7 {
		return rgb{hexByte(s[1], s[2]), hexByte(s[3], s[4]), hexByte(s[5], s[6])}
	}
	return rgb{hexByte(s[1], s[1]), hexByte(s[2], s[2]), hexByte(s[3], s[3])}
}

func hexByte(hi, lo byte) int { return hexDigit(hi)<<4 | hexDigit(lo) }

func hexDigit(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	default:
		return int(c-'A') + 10
	}
}

func toHex(c rgb) string { return fmt.Sprintf("#%02x%02x%02x", c[0], c[1], c[2]) }

func relativeLuminance(c rgb) float64 {
	var ch [3]float64
	for i, channel := range c {
		value := float64(channel) / 255.0
		if value <= 0.03928 {
			ch[i] = value / 12.92
		} else {
			ch[i] = math.Pow((value+0.055)/1.055, 2.4)
		}
	}
	return float64(0.2126*ch[0]) + float64(0.7152*ch[1]) + float64(0.0722*ch[2])
}

func contrastRatio(luminance, other float64) float64 {
	return (math.Max(luminance, other) + 0.05) / (math.Min(luminance, other) + 0.05)
}

// contrastFor is ContrastColor.for.
func (j *judge) contrastFor(c rgb) string {
	luminance := relativeLuminance(c)
	withWhite := contrastRatio(luminance, relativeLuminance(whiteRGB))
	withBlack := contrastRatio(luminance, relativeLuminance(blackRGB))
	if j.gt(withWhite, withBlack) {
		return white
	}
	return black
}

func ratioBetween(a, b rgb) float64 {
	return contrastRatio(relativeLuminance(a), relativeLuminance(b))
}

func (j *judge) apcaScreenLuminance(c rgb) float64 {
	r := math.Pow(float64(c[0])/255.0, 2.4)
	g := math.Pow(float64(c[1])/255.0, 2.4)
	b := math.Pow(float64(c[2])/255.0, 2.4)
	y := float64(0.2126729*r) + float64(0.7151522*g) + float64(0.0721750*b)
	if j.lt(y, 0.022) {
		return y + math.Pow(0.022-y, 1.414)
	}
	return y
}

func (j *judge) apcaLc(text, background rgb) float64 {
	textY := j.apcaScreenLuminance(text)
	backgroundY := j.apcaScreenLuminance(background)
	if j.lt(math.Abs(backgroundY-textY), 0.0005) {
		return 0
	}
	if j.gt(backgroundY, textY) {
		contrast := float64((math.Pow(backgroundY, 0.56) - math.Pow(textY, 0.57)) * 1.14)
		if j.lt(contrast, 0.1) {
			return 0
		}
		return (contrast - 0.027) * 100
	}
	contrast := float64((math.Pow(backgroundY, 0.65) - math.Pow(textY, 0.62)) * 1.14)
	if j.gt(contrast, -0.1) {
		return 0
	}
	return (contrast + 0.027) * 100
}

func (j *judge) prefersWhiteText(c rgb) bool {
	return j.gt(math.Abs(j.apcaLc(whiteRGB, c)), math.Abs(j.apcaLc(blackRGB, c)))
}

func (j *judge) apcaScoresAreClose(c rgb) bool {
	return j.le(math.Abs(math.Abs(j.apcaLc(whiteRGB, c))-math.Abs(j.apcaLc(blackRGB, c))), apcaTieBand)
}

func (j *judge) brightnessShiftFor(c rgb, whiteText bool) int {
	text := blackRGB
	if whiteText {
		text = whiteRGB
	}
	if j.ge(contrastRatio(relativeLuminance(c), relativeLuminance(text)), wcagAANormalText) {
		return 0
	}
	low, high := 0, 255
	for low < high {
		middle := (low + high) / 2
		shifted := shiftBrightness(c, whiteText, middle)
		if j.ge(contrastRatio(relativeLuminance(shifted), relativeLuminance(text)), wcagAANormalText) {
			high = middle
		} else {
			low = middle + 1
		}
	}
	return low
}

func shiftBrightness(c rgb, whiteText bool, step int) rgb {
	target := 255
	if whiteText {
		target = 0
	}
	var out rgb
	for i, channel := range c {
		out[i] = int(math.Floor(float64(channel) + float64((target-channel)*step)/255.0))
	}
	return out
}

// accessibleAccent is ContrastColor.accessible_accent: the accent to fill text areas with and
// the text colour on it.
func (j *judge) accessibleAccent(c rgb) (accent rgb, text string) {
	whiteText := j.prefersWhiteText(c)
	displayShift := j.brightnessShiftFor(c, whiteText)
	otherShift := j.brightnessShiftFor(c, !whiteText)
	if otherShift < displayShift && j.apcaScoresAreClose(c) {
		whiteText = !whiteText
		displayShift = otherShift
	}
	text = black
	if whiteText {
		text = white
	}
	return shiftBrightness(c, whiteText, displayShift), text
}
