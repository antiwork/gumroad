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

  # How close the two APCA readability scores have to be before we stop trusting the winner and
  # break the tie on "which choice needs the accent changed least". Roughly the point where a
  # person can no longer tell which of black or white reads better, so we may as well pick the one
  # that leaves the seller's colour alone.
  APCA_TIE_BAND = 10.0

  # If the more readable text colour would force us to move the accent's brightness by more than
  # this many 0-255 steps, and the other text colour needs a smaller move, take the other one. This
  # keeps "the seller's colour barely changes" as the priority when the readability difference is
  # real but the cost of honouring it is a visibly different colour.
  MAX_BRIGHTNESS_SHIFT = 32

  # The largest brightness shift `accessible_accent` ever applies, measured by sweeping the sRGB
  # space (see the spec, which pins it). Expressed in 0-255 steps of the mix toward black/white.
  WORST_CASE_BRIGHTNESS_SHIFT = 32

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
  # 1. Which text colour looks more readable? That is judged with APCA (the perceptual contrast
  #    model being developed for WCAG 3), because it models how text of a given lightness reads on
  #    a background far better than the WCAG 2 ratio does. APCA says white on pure red, which is
  #    what a designer would choose and what sellers expect.
  # 2. Does that pair clear the 4.5:1 WCAG AA floor? White on #ff0000 does not (4.00:1). If it
  #    doesn't, darken the accent for white text (or lighten it for black text) by the smallest
  #    amount that does. #ff0000 becomes #ee0000 — same red to the eye, now 4.53:1 with white.
  # 3. Sanity-check the choice against its cost. If the two APCA scores are within APCA_TIE_BAND of
  #    each other, or if honouring the winner would move the accent by more than
  #    MAX_BRIGHTNESS_SHIFT steps, and the other text colour needs a smaller move, use the other
  #    one instead. This is what keeps "we changed your brand colour a lot" from being the price of
  #    a readability difference nobody can see.
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
    shift_for_white = brightness_shift_for(rgb, white_text: true)
    shift_for_black = brightness_shift_for(rgb, white_text: false)

    chosen_shift, other_shift = white_text ? [shift_for_white, shift_for_black] : [shift_for_black, shift_for_white]
    if other_shift < chosen_shift && (apca_scores_are_close?(rgb) || chosen_shift > MAX_BRIGHTNESS_SHIFT)
      white_text = !white_text
      chosen_shift = other_shift
    end

    { accent: to_hex(shift_brightness(rgb, white_text:, step: chosen_shift)), text: white_text ? WHITE : BLACK }
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

  # APCA lightness contrast (Lc), as an absolute 0-106ish score: how readable text of one colour is
  # on a background of another. Unlike the WCAG 2 ratio it is asymmetric — dark-on-light and
  # light-on-dark are scored with different exponents, which is the whole reason it agrees with the
  # eye on saturated hues where the WCAG ratio does not. Constants are from the APCA 0.1.9 formula.
  # https://github.com/Myndex/SAPC-APCA
  def self.apca_lc(text_rgb, background_rgb)
    text_y = apca_screen_luminance(text_rgb)
    background_y = apca_screen_luminance(background_rgb)
    return 0.0 if (background_y - text_y).abs < 0.0005

    contrast = if background_y > text_y # dark text on a lighter background
      ((background_y**0.56) - (text_y**0.57)) * 1.14
    else # light text on a darker background
      ((background_y**0.65) - (text_y**0.62)) * 1.14
    end

    # Near-zero contrast is clamped to 0 and low contrast is scaled down, so that trivially
    # different colours don't report a misleadingly usable score.
    scaled = if contrast.abs < 0.001
      0.0
    elsif contrast.abs > 0.035991
      contrast - (contrast.positive? ? 0.027 : -0.027)
    else
      contrast * 27.7847239587675
    end

    (scaled * 100).abs
  end

  # APCA's own luminance measure. Same idea as WCAG relative luminance but with a simple 2.4-power
  # curve per channel and a soft clamp near black, which is what makes it track perceived
  # readability on very dark colours.
  def self.apca_screen_luminance(rgb)
    r, g, b = rgb.map { (_1 / 255.0)**2.4 }
    y = (0.2126729 * r) + (0.7151522 * g) + (0.0721750 * b)

    y < 0.022 ? y + ((0.022 - y)**1.414) : y
  end

  # True when APCA rates white text on this colour as more readable than black text.
  def self.prefers_white_text?(rgb)
    apca_lc(parse(WHITE), rgb) > apca_lc(parse(BLACK), rgb)
  end
  private_class_method :prefers_white_text?

  def self.apca_scores_are_close?(rgb)
    (apca_lc(parse(WHITE), rgb) - apca_lc(parse(BLACK), rgb)).abs <= APCA_TIE_BAND
  end
  private_class_method :apca_scores_are_close?

  # Smallest number of 0-255 steps toward black (for white text) or toward white (for black text)
  # that brings the pair to the WCAG AA floor. Binary search is safe because mixing steadily toward
  # black or white moves the contrast ratio in one direction only.
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
  private_class_method :brightness_shift_for

  # Mixes the colour `step`/255 of the way toward black (when the text will be white) or toward
  # white (when the text will be black). `floor` rather than `round` because the browser
  # implementation has to land on the identical byte and Ruby and JavaScript round halves
  # differently.
  def self.shift_brightness(rgb, white_text:, step:)
    target = white_text ? 0 : 255
    rgb.map { (_1 + ((target - _1) * step / 255.0)).floor }
  end
  private_class_method :shift_brightness

  def self.to_hex(rgb)
    "#%02x%02x%02x" % rgb
  end
  private_class_method :to_hex

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
