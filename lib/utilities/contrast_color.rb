# frozen_string_literal: true

# Picks the readable text colour (black or white) to put on top of a seller-chosen colour.
#
# Sellers choose their storefront accent and background colours freely, and we have to pick the
# text colour that goes on top of them. The obvious-looking test — "is this colour light?" — is
# the wrong question, because two colours can be equally "light" in the HSL sense while looking
# nothing alike to a human eye. HSL lightness is just (max + min) / 2 of the raw red/green/blue
# channels, so it treats a saturated green and a mid grey as equally light even though the green
# looks far brighter. A bright green accent therefore used to be classed as "dark" and get white
# text on top of it, at a contrast ratio of 1.37:1 — effectively invisible.
#
# The right question is which of black or white actually contrasts more against the colour, so
# that is what this does: it computes the WCAG contrast ratio both ways and returns the winner.
# There is no threshold to sit on the wrong side of.
#
# Worth knowing: this makes an unreadable result impossible rather than merely unlikely. Checking
# all 16,777,216 sRGB colours, the worst case for "whichever of black or white contrasts more" is
# 4.58:1, which still clears the WCAG AA minimum of 4.5:1 for normal-size text. So every colour a
# seller can possibly pick ends up with readable text on it. `contrast_color_spec.rb` pins that
# guarantee down so it cannot quietly regress.
module ContrastColor
  WHITE = "#ffffff"
  BLACK = "#000000"

  # The lowest contrast ratio reachable by this function over the whole sRGB space, verified
  # exhaustively (see the spec). Kept here so the guarantee is visible next to the code that
  # provides it, and so the spec has a named constant to assert against.
  WORST_CASE_CONTRAST_RATIO = 4.58

  # WCAG AA requires 4.5:1 for normal-size text.
  WCAG_AA_NORMAL_TEXT = 4.5

  # Returns "#ffffff" or "#000000", whichever is more readable on top of the given colour.
  # Anything that isn't a #rrggbb hex string falls back to black, matching how the rest of the
  # storefront styling degrades on an unexpected value rather than raising mid-render.
  def self.for(hex_color)
    rgb = parse(hex_color)
    return BLACK if rgb.nil?

    luminance = relative_luminance(rgb)
    contrast_with_white = contrast_ratio(luminance, relative_luminance(parse(WHITE)))
    contrast_with_black = contrast_ratio(luminance, relative_luminance(parse(BLACK)))

    contrast_with_white > contrast_with_black ? WHITE : BLACK
  end

  # WCAG contrast ratio between two #rrggbb colours, e.g. 15.36 for black on bright green.
  def self.ratio_between(hex_color, other_hex_color)
    a = parse(hex_color)
    b = parse(other_hex_color)
    return nil if a.nil? || b.nil?

    contrast_ratio(relative_luminance(a), relative_luminance(b))
  end

  # WCAG relative luminance: how bright a colour actually looks, on a 0 (black) to 1 (white)
  # scale. Each channel is first un-gamma-corrected, then weighted, because the eye is much more
  # sensitive to green than to blue — green carries roughly 72% of perceived brightness and blue
  # only about 7%. That weighting is exactly what HSL lightness leaves out.
  # https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
  def self.relative_luminance(rgb)
    r, g, b = rgb.map do |channel|
      value = channel / 255.0
      value <= 0.03928 ? value / 12.92 : (((value + 0.055) / 1.055)**2.4)
    end

    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  # https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
  def self.contrast_ratio(luminance, other_luminance)
    lighter = [luminance, other_luminance].max
    darker = [luminance, other_luminance].min

    (lighter + 0.05) / (darker + 0.05)
  end

  # Returns [r, g, b] with each channel 0-255, or nil if the value isn't a hex colour.
  #
  # Both the 6-digit (#rrggbb) and 3-digit (#rgb) forms are accepted. The 3-digit form matters
  # because the column is only validated on normal saves — `update_attribute`, `update_column` and
  # raw SQL all bypass that — and the SCSS `lightness()` function this replaced understood 3-digit
  # hex natively. Rejecting it here would have quietly changed the colour on any row holding one.
  def self.parse(hex_color)
    value = hex_color.to_s.strip
    return [value[1, 2], value[3, 2], value[5, 2]].map { _1.to_i(16) } if value.match?(/\A#[0-9a-f]{6}\z/i)
    # In the 3-digit form each digit is doubled, so #f0a means the same colour as #ff00aa.
    return value[1..].chars.map { (_1 * 2).to_i(16) } if value.match?(/\A#[0-9a-f]{3}\z/i)

    nil
  end

  private_class_method :parse
end
