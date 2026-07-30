# frozen_string_literal: true

# Picks readable text colours to put on top of the colours a seller chooses for their storefront.
#
# Sellers pick their accent and background colours freely, and we have to decide what colour of
# text goes on top of them. The obvious-looking test — "is this colour light?" — is the wrong
# question, because two colours can be equally "light" in the HSL sense while looking nothing
# alike to a human eye. HSL lightness is just (max + min) / 2 of the raw red/green/blue channels,
# so it treats a saturated green and a mid grey as equally light even though the green looks far
# brighter. A bright green accent therefore used to be classed as "dark" and get white text on top
# of it, at a contrast ratio of 1.37:1 — effectively invisible.
#
# There are two related jobs in here:
#
# `for` answers "black or white on this colour?" by computing the WCAG contrast ratio both ways
# and returning the winner. It is used for the storefront background and for body text, where the
# colour underneath cannot be adjusted. Checking all 16,777,216 sRGB colours, its worst case is
# 4.58:1, which still clears the WCAG AA minimum of 4.5:1 for normal-size text.
#
# `accessible_accent` answers the harder question for the accent colour — the pay button, the
# offer banner price, anything filled with the seller's highlight colour and carrying text. See
# the comment on that method for why "whichever of black or white contrasts more" is not enough
# there, and what we do instead.
module ContrastColor
  WHITE = "#ffffff"
  BLACK = "#000000"

  # The lowest contrast ratio reachable by `for` over the whole sRGB space, verified exhaustively
  # (see the spec). Kept here so the guarantee is visible next to the code that provides it, and
  # so the spec has a named constant to assert against.
  WORST_CASE_CONTRAST_RATIO = 4.58

  # WCAG AA requires 4.5:1 for normal-size text. This is a hard floor: no accent/text pair we
  # render is ever allowed below it.
  WCAG_AA_NORMAL_TEXT = 4.5

  # WCAG 2.2 SC 1.4.11 requires 3:1 for non-text state indicators.
  WCAG_AA_NON_TEXT = 3.0

  # visible_indicator rescues only colours below this ratio — ones that have vanished into their
  # background. This knowingly accepts indicators under WCAG 1.4.11's 3:1: recolouring an accent a
  # buyer can already see made focus states harder to spot, and shipping that was rejected on
  # review (#6588, decided in #6581). At or above this, the seller's colour renders untouched.
  INDICATOR_VISIBILITY_FLOOR = 1.5

  # Relative luminance of #808080, used to choose the direction of the brightness shift.
  BACKGROUND_LUMINANCE_MIDPOINT = 0.2159

  # If APCA rates black and white within 10 Lc of each other, neither has a strong perceptual lead.
  # In that narrow case, prefer the one that changes the creator's colour less.
  APCA_TIE_BAND = 10.0

  # Match JavaScript's String#trim exactly. Ruby's [[:space:]] also removes U+0085, which
  # JavaScript keeps; using that broader class would make the live storefront accept a value that
  # the editor preview rejects.
  JAVASCRIPT_TRIM = /\A[\u{0009}-\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}]+|[\u{0009}-\u{000d}\u{0020}\u{00a0}\u{1680}\u{2000}-\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}]+\z/

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

  # Returns the pair to actually render for an accent area that contains text:
  # { accent: "#rrggbb", text: "#ffffff" | "#000000" }.
  #
  # `accent` is the seller's colour with its brightness nudged if — and only if — that was needed
  # to clear 4.5:1. What the seller saved is never modified; this is a display-time adjustment.
  #
  # Why the simple "whichever of black or white contrasts more" rule isn't enough here: on a
  # saturated warm hue the two candidates land close together on opposite sides of a hard flip.
  # Pure red #ff0000 scores 4.00:1 with white and 5.25:1 with black, so black wins — yet three hex
  # steps away at #ec0000 the winner is white, and the two reds are indistinguishable to the eye.
  # Sellers with a red accent saw the price on their pay button go black, which reads as broken
  # even though it is technically the higher-contrast option. The flip is arbitrary: it sits
  # wherever the two ratios happen to cross.
  #
  # So we ask a better question in three steps.
  #
  # 1. Which text colour looks more readable? APCA is used as a non-normative perceptual ranking.
  #    It says white on pure red, which is what sellers expect.
  # 2. Does that pair clear the 4.5:1 WCAG AA floor? White on #ff0000 does not (4.00:1). If it
  #    doesn't, darken the accent for white text (or lighten it for black text) by the smallest
  #    amount that does. #ff0000 becomes #ee0000 — same red to the eye, now 4.53:1 with white.
  # 3. If APCA rates black and white within APCA_TIE_BAND of each other, neither has a strong
  #    perceptual lead, so use the one that changes the creator's colour less. Outside that tie,
  #    honour APCA and apply exactly the minimum WCAG adjustment.
  #
  # The floor in step 2 is never traded away — the point of this method is to satisfy it without
  # making the text colour flip on invisible boundaries, and without looking at the page background
  # (the accent has to work on light and dark storefronts alike, so the surrounding colour is
  # deliberately not an input).
  #
  # Keep this in step with getAccessibleAccent in app/javascript/utils/color.ts: the server renders
  # the live storefront CSS and the browser renders the editor preview, so a divergence means a
  # seller sees one colour while setting up and a different one on their store. The shared fixture
  # in spec/fixtures/accent_contrast_pairs.json is asserted by both test suites for exactly that.
  def self.accessible_accent(hex_color)
    rgb = parse(hex_color)
    return { accent: BLACK, text: WHITE } if rgb.nil?

    white_text = prefers_white_text?(rgb)
    display_shift = brightness_shift_for(rgb, white_text:)
    other_shift = brightness_shift_for(rgb, white_text: !white_text)

    if other_shift < display_shift && apca_scores_are_close?(rgb)
      white_text = !white_text
      display_shift = other_shift
    end

    {
      accent: to_hex(shift_brightness(rgb, white_text:, step: display_shift)),
      text: white_text ? WHITE : BLACK
    }
  end

  # Returns the seller's colour untouched whenever a buyer can perceive it against the background
  # (INDICATOR_VISIBILITY_FLOOR). A colour below that has disappeared entirely, so it is shifted in
  # brightness — hue preserved — until it clears the non-text floor: once we replace a colour, the
  # replacement should be plainly visible, not the least-visible legal one.
  def self.visible_indicator(hex_color, background_hex)
    rgb = parse(hex_color)
    background = parse(background_hex)
    return BLACK if rgb.nil? || background.nil?
    return to_hex(rgb) unless indicator_imperceptible?(rgb, background)

    # Moving away from the background keeps contrast monotonic for the binary search.
    white_text = relative_luminance(background) > BACKGROUND_LUMINANCE_MIDPOINT
    low = 0
    high = 255
    while low < high
      middle = (low + high) / 2
      if indicator_contrast_ok?(shift_brightness(rgb, white_text:, step: middle), background)
        high = middle
      else
        low = middle + 1
      end
    end

    to_hex(shift_brightness(rgb, white_text:, step: low))
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

  # APCA lightness contrast (Lc), as a signed score: positive for dark text on a light background
  # and negative for light text on a dark background. Unlike the WCAG 2 ratio it is asymmetric. We
  # use only its magnitude to rank black against white; WCAG 2.2 compliance still comes from the
  # 4.5:1 floor below. Constants and clipping match APCA 0.1.9.
  # https://github.com/Myndex/SAPC-APCA
  def self.apca_lc(text_rgb, background_rgb)
    text_y = apca_screen_luminance(text_rgb)
    background_y = apca_screen_luminance(background_rgb)
    return 0.0 if (background_y - text_y).abs < 0.0005

    if background_y > text_y # dark text on a lighter background
      contrast = ((background_y**0.56) - (text_y**0.57)) * 1.14
      contrast < 0.1 ? 0.0 : (contrast - 0.027) * 100
    else # light text on a darker background
      contrast = ((background_y**0.65) - (text_y**0.62)) * 1.14
      contrast > -0.1 ? 0.0 : (contrast + 0.027) * 100
    end
  end

  # APCA's own luminance measure. Same idea as WCAG relative luminance but with a simple 2.4-power
  # curve per channel and a soft clamp near black, which is what makes it track perceived
  # readability on very dark colours.
  def self.apca_screen_luminance(rgb)
    r, g, b = rgb.map { (_1 / 255.0)**2.4 }
    y = (0.2126729 * r) + (0.7151522 * g) + (0.0721750 * b)

    y < 0.022 ? y + ((0.022 - y)**1.414) : y
  end

  def self.indicator_contrast_ok?(rgb, background)
    contrast_ratio(relative_luminance(rgb), relative_luminance(background)) >= WCAG_AA_NON_TEXT
  end
  private_class_method :indicator_contrast_ok?

  def self.indicator_imperceptible?(rgb, background)
    contrast_ratio(relative_luminance(rgb), relative_luminance(background)) < INDICATOR_VISIBILITY_FLOOR
  end
  private_class_method :indicator_imperceptible?

  # True when APCA rates white text on this colour as more readable than black text.
  def self.prefers_white_text?(rgb)
    apca_lc(parse(WHITE), rgb).abs > apca_lc(parse(BLACK), rgb).abs
  end
  private_class_method :prefers_white_text?

  def self.apca_scores_are_close?(rgb)
    (apca_lc(parse(WHITE), rgb).abs - apca_lc(parse(BLACK), rgb).abs).abs <= APCA_TIE_BAND
  end
  private_class_method :apca_scores_are_close?

  # Smallest number of 0-255 steps toward black (for white text) or toward white (for black text)
  # that brings the pair to the WCAG AA floor. Binary search is safe because mixing steadily toward
  # black or white moves the contrast ratio in one direction only.
  #
  # Public because it is one of the two building blocks a caller needs to check the result is
  # minimal: the spec asserts one step less than this fails.
  def self.brightness_shift_for(rgb, white_text:)
    text = parse(white_text ? WHITE : BLACK)
    return 0 if contrast_ratio(relative_luminance(rgb), relative_luminance(text)) >= WCAG_AA_NORMAL_TEXT

    low = 0
    high = 255
    while low < high
      middle = (low + high) / 2
      shifted = shift_brightness(rgb, white_text:, step: middle)
      if contrast_ratio(relative_luminance(shifted), relative_luminance(text)) >= WCAG_AA_NORMAL_TEXT
        high = middle
      else
        low = middle + 1
      end
    end

    low
  end

  # Mixes the colour `step`/255 of the way toward black (when the text will be white) or toward
  # white (when the text will be black). `floor` rather than `round` because the browser
  # implementation has to land on the identical byte and Ruby and JavaScript round halves
  # differently. Public alongside brightness_shift_for, for the same reason.
  def self.shift_brightness(rgb, white_text:, step:)
    target = white_text ? 0 : 255
    rgb.map { (_1 + ((target - _1) * step / 255.0)).floor }
  end

  # Formats [r, g, b] as #rrggbb. Public because callers that interpolate a colour into a <style>
  # block need to be able to state where the string came from.
  def self.to_hex(rgb)
    "#%02x%02x%02x" % rgb
  end

  # Returns [r, g, b] with each channel 0-255, or nil if the value isn't a hex colour.
  #
  # Both the 6-digit (#rrggbb) and 3-digit (#rgb) forms are accepted. The 3-digit form matters
  # because the column is only validated on normal saves — `update_attribute`, `update_column` and
  # raw SQL all bypass that — and the SCSS `lightness()` function this replaced understood 3-digit
  # hex natively. Rejecting it here would have quietly changed the colour on any row holding one.
  def self.parse(hex_color)
    value = hex_color.to_s.gsub(JAVASCRIPT_TRIM, "")
    return [value[1, 2], value[3, 2], value[5, 2]].map { _1.to_i(16) } if value.match?(/\A#[0-9a-f]{6}\z/i)
    # In the 3-digit form each digit is doubled, so #f0a means the same colour as #ff00aa.
    return value[1..].chars.map { (_1 * 2).to_i(16) } if value.match?(/\A#[0-9a-f]{3}\z/i)

    nil
  end
end
