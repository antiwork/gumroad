// Code generated from loofah 2.25.1's lib/loofah/html5/safelist.rb and scrub.rb. DO NOT EDIT.

package csssan

import "regexp"

var (
	// Scrub::CSS_KEYWORDISH.
	cssKeywordish = regexp.MustCompile(`\A(#[0-9a-fA-F]+|rgb\(\d+%?,\d*%?,?\d*%?\)?|-?\d{0,3}\.?\d{0,10}(ch|cm|r?em|ex|in|lh|mm|pc|pt|px|Q|vmax|vmin|vw|vh|%|,|\))?)\z`)
	// Scrub::URI_PROTOCOL_REGEX.
	uriProtocol = regexp.MustCompile(`\A[a-z][a-z0-9+\-.]*:`)
)

// SafeList::ALLOWED_CSS_PROPERTIES, before Gumroad adds "position".
var allowedCSSProperties = setOf(
	"align-content", "align-items", "align-self", "aspect-ratio", "azimuth", "background-color",
	"border-bottom-color", "border-collapse", "border-color", "border-left-color",
	"border-right-color", "border-top-color", "clear", "color", "cursor", "direction",
	"display", "elevation", "flex", "flex-basis", "flex-direction", "flex-flow", "flex-grow",
	"flex-shrink", "flex-wrap", "float", "font", "font-family", "font-size", "font-style",
	"font-variant", "font-weight", "height", "justify-content", "letter-spacing", "line-height",
	"list-style", "list-style-type", "max-height", "max-width", "min-height", "min-width",
	"order", "overflow", "overflow-x", "overflow-y", "page-break-after", "page-break-before",
	"page-break-inside", "pause", "pause-after", "pause-before", "pitch", "pitch-range",
	"richness", "speak", "speak-header", "speak-numeral", "speak-punctuation", "speech-rate",
	"stress", "text-align", "text-decoration", "text-indent", "unicode-bidi", "vertical-align",
	"voice-family", "volume", "white-space", "width",
)

// SafeList::ALLOWED_SVG_PROPERTIES.
var allowedSVGProperties = setOf(
	"fill", "fill-opacity", "fill-rule", "stroke", "stroke-linecap", "stroke-linejoin",
	"stroke-opacity", "stroke-width",
)

// SafeList::SHORTHAND_CSS_PROPERTIES.
var shorthandCSSProperties = setOf(
	"background", "border", "margin", "padding",
)

// SafeList::ALLOWED_CSS_KEYWORDS.
var allowedCSSKeywords = setOf(
	"!important", "aliceblue", "antiquewhite", "aqua", "aquamarine", "auto", "azure", "beige",
	"bisque", "black", "blanchedalmond", "block", "blue", "blueviolet", "bold", "both",
	"bottom", "brown", "burlywood", "cadetblue", "center", "chartreuse", "chocolate",
	"collapse", "coral", "cornflowerblue", "cornsilk", "crimson", "cyan", "darkblue",
	"darkcyan", "darkgoldenrod", "darkgray", "darkgreen", "darkgrey", "darkkhaki",
	"darkmagenta", "darkolivegreen", "darkorange", "darkorchid", "darkred", "darksalmon",
	"darkseagreen", "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise",
	"darkviolet", "dashed", "deeppink", "deepskyblue", "dimgray", "dimgrey", "dodgerblue",
	"dotted", "double", "firebrick", "floralwhite", "forestgreen", "fuchsia", "gainsboro",
	"ghostwhite", "gold", "goldenrod", "gray", "green", "greenyellow", "grey", "groove",
	"hidden", "honeydew", "hotpink", "indianred", "indigo", "inherit", "initial", "inset",
	"italic", "ivory", "khaki", "lavender", "lavenderblush", "lawngreen", "left",
	"lemonchiffon", "lightblue", "lightcoral", "lightcyan", "lightgoldenrodyellow", "lightgray",
	"lightgreen", "lightgrey", "lightpink", "lightsalmon", "lightseagreen", "lightskyblue",
	"lightslategray", "lightslategrey", "lightsteelblue", "lightyellow", "lime", "limegreen",
	"linen", "magenta", "maroon", "medium", "mediumaquamarine", "mediumblue", "mediumorchid",
	"mediumpurple", "mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise",
	"mediumvioletred", "midnightblue", "mintcream", "mistyrose", "moccasin", "navajowhite",
	"navy", "none", "normal", "nowrap", "oldlace", "olive", "olivedrab", "orange", "orangered",
	"orchid", "outset", "palegoldenrod", "palegreen", "paleturquoise", "palevioletred",
	"papayawhip", "peachpuff", "peru", "pink", "plum", "pointer", "powderblue", "purple", "red",
	"revert", "ridge", "right", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown",
	"seagreen", "seashell", "separate", "sienna", "silver", "skyblue", "slateblue", "slategray",
	"slategrey", "snow", "solid", "springgreen", "steelblue", "tan", "teal", "thick", "thin",
	"thistle", "tomato", "top", "transparent", "turquoise", "underline", "unset", "violet",
	"wheat", "white", "whitesmoke", "yellow", "yellowgreen",
)

// SafeList::ALLOWED_CSS_FUNCTIONS.
var allowedCSSFunctions = setOf(
	"attr", "blur", "brightness", "calc", "circle", "contrast", "counter", "counters",
	"cubic-bezier", "drop-shadow", "ellipse", "grayscale", "hsl", "hsla", "hue-rotate", "hwb",
	"inset", "invert", "linear-gradient", "matrix", "matrix3d", "opacity", "perspective",
	"polygon", "radial-gradient", "repeating-linear-gradient", "repeating-radial-gradient",
	"rgb", "rgba", "rotate", "rotate3d", "rotateX", "rotateY", "rotateZ", "rotatex", "rotatey",
	"rotatez", "saturate", "scale", "scale3d", "scaleX", "scaleY", "scaleZ", "scalex", "scaley",
	"scalez", "sepia", "skew", "skewX", "skewY", "skewx", "skewy", "symbols", "translate",
	"translate3d", "translateX", "translateY", "translateZ", "translatex", "translatey",
	"translatez",
)

// SafeList::ALLOWED_PROTOCOLS.
var allowedProtocols = setOf(
	"afs", "aim", "callto", "data", "ed2k", "fax", "feed", "ftp", "gopher", "http", "https",
	"irc", "line", "mailto", "modem", "news", "nntp", "rsync", "rtsp", "sftp", "sms", "ssh",
	"tag", "tel", "telnet", "urn", "webcal", "xmpp",
)

// SafeList::ALLOWED_URI_DATA_MEDIATYPES.
var allowedURIDataMediatypes = setOf(
	"image/gif", "image/jpeg", "image/png", "text/css", "text/plain",
)

// SafeList::ALLOWED_ATTRIBUTES.
var allowedAttributes = setOf(
	"abbr", "accent-height", "accept", "accept-charset", "accesskey", "accumulate", "action",
	"actiontype", "additive", "align", "alphabetic", "alt", "arabic-form",
	"aria-activedescendant", "aria-atomic", "aria-autocomplete", "aria-braillelabel",
	"aria-brailleroledescription", "aria-busy", "aria-checked", "aria-colcount",
	"aria-colindex", "aria-colindextext", "aria-colspan", "aria-controls", "aria-current",
	"aria-describedby", "aria-description", "aria-details", "aria-disabled", "aria-dropeffect",
	"aria-errormessage", "aria-expanded", "aria-flowto", "aria-grabbed", "aria-haspopup",
	"aria-hidden", "aria-invalid", "aria-keyshortcuts", "aria-label", "aria-labelledby",
	"aria-level", "aria-live", "aria-multiline", "aria-multiselectable", "aria-orientation",
	"aria-owns", "aria-placeholder", "aria-posinset", "aria-pressed", "aria-readonly",
	"aria-relevant", "aria-required", "aria-roledescription", "aria-rowcount", "aria-rowindex",
	"aria-rowindextext", "aria-rowspan", "aria-selected", "aria-setsize", "aria-sort",
	"aria-valuemax", "aria-valuemin", "aria-valuenow", "aria-valuetext", "ascent",
	"attributeName", "attributeType", "attributename", "attributetype", "axis", "baseProfile",
	"baseprofile", "bbox", "begin", "border", "calcMode", "calcmode", "cap-height",
	"cellpadding", "cellspacing", "char", "charoff", "charset", "checked", "cite", "class",
	"clear", "clip-path", "clip-rule", "close", "color", "color-interpolation-filters",
	"color-profile", "color-rendering", "cols", "colspan", "columnalign", "columnlines",
	"columnspacing", "columnspan", "compact", "content", "contenteditable", "coords", "cursor",
	"cx", "cy", "d", "datetime", "depth", "descent", "dir", "disabled", "display",
	"displaystyle", "dur", "dx", "dy", "encoding", "enctype", "end", "equalcolumns",
	"equalrows", "fence", "fill", "fill-opacity", "fill-rule", "filter", "filterRes",
	"filterUnits", "filterres", "filterunits", "font-family", "font-size", "font-stretch",
	"font-style", "font-variant", "font-weight", "fontstyle", "fontweight", "for", "frame",
	"fx", "fy", "g1", "g2", "glyph-name", "gradientUnits", "gradientunits", "hanging",
	"headers", "height", "horiz-adv-x", "horiz-origin-x", "href", "hreflang", "hspace", "id",
	"ideographic", "ismap", "k", "keyPoints", "keySplines", "keyTimes", "keypoints",
	"keysplines", "keytimes", "label", "lang", "linethickness", "longdesc", "loop", "loopcount",
	"loopend", "loopstart", "lquote", "lspace", "marker", "marker-end", "marker-mid",
	"marker-start", "markerHeight", "markerUnits", "markerWidth", "markerheight", "markerunits",
	"markerwidth", "mask", "maskContentUnits", "maskUnits", "maskcontentunits", "maskunits",
	"mathbackground", "mathcolor", "mathematical", "mathsize", "mathvariant", "max",
	"maxlength", "maxsize", "media", "method", "min", "minsize", "multiple", "name", "nohref",
	"noshade", "notation", "nowrap", "offset", "opacity", "open", "orient", "origin", "other",
	"overline-position", "overline-thickness", "panose-1", "path", "pathLength", "pathlength",
	"patternContentUnits", "patternTransform", "patternUnits", "patterncontentunits",
	"patterntransform", "patternunits", "points", "poster", "preload", "preserveAspectRatio",
	"preserveaspectratio", "primitiveUnits", "primitiveunits", "prompt", "r", "readonly",
	"refX", "refY", "refx", "refy", "rel", "repeatCount", "repeatDur", "repeatcount",
	"repeatdur", "requiredExtensions", "requiredFeatures", "requiredextensions",
	"requiredfeatures", "restart", "rev", "role", "rotate", "rowalign", "rowlines", "rows",
	"rowspacing", "rowspan", "rquote", "rspace", "rules", "rx", "ry", "scope", "scriptlevel",
	"selected", "selection", "separator", "separators", "shape", "size", "slope", "spacing",
	"span", "src", "start", "startOffset", "startoffset", "stdDeviation", "stddeviation",
	"stemh", "stemv", "stop-color", "stop-opacity", "stretchy", "strikethrough-position",
	"strikethrough-thickness", "stroke", "stroke-dasharray", "stroke-dashoffset",
	"stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity", "stroke-width",
	"style", "summary", "systemLanguage", "systemlanguage", "tabindex", "target", "text-anchor",
	"title", "transform", "type", "u1", "u2", "underline-position", "underline-thickness",
	"unicode", "unicode-range", "units-per-em", "usemap", "valign", "value", "version",
	"viewBox", "viewbox", "visibility", "vspace", "width", "widths", "x", "x-height", "x1",
	"x2", "xlink:actuate", "xlink:arcrole", "xlink:href", "xlink:role", "xlink:show",
	"xlink:title", "xlink:type", "xml:base", "xml:lang", "xml:space", "xmlns", "xmlns:xlink",
	"y", "y1", "y2", "zoomAndPan", "zoomandpan",
)

// SafeList::ATTR_VAL_IS_URI.
var attrValIsURI = setOf(
	"action", "cite", "href", "longdesc", "poster", "preload", "src", "xlink:href", "xml:base",
)

// SafeList::SVG_ATTR_VAL_ALLOWS_REF.
var svgAttrValAllowsRef = setOf(
	"clip-path", "color-profile", "cursor", "fill", "filter", "marker", "marker-end",
	"marker-mid", "marker-start", "mask", "stroke",
)
