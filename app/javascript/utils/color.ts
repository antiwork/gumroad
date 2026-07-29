// WCAG AA requires 4.5:1 for normal-size text. This is a hard floor: no accent/text pair we render
// is ever allowed below it.
export const WCAG_AA_NORMAL_TEXT = 4.5;

// If APCA rates black and white within 10 Lc of each other, neither has a strong perceptual lead.
// In that narrow case, prefer the one that changes the creator's colour less.
const APCA_TIE_BAND = 10;

const WHITE = "#ffffff";
const BLACK = "#000000";

// Expands a hex colour to [r, g, b] with each channel 0-255, or null if it isn't one.
//
// Both the 6-digit (#rrggbb) and 3-digit (#rgb) forms are accepted. The 3-digit form matters
// because the stored colour is only validated on normal saves, so a row can hold one, and the
// SCSS function this logic replaced understood 3-digit hex natively.
const parseHex = (hex: string) => {
  const value = hex.trim();
  const digits =
    /^#([0-9a-f]{6})$/iu.exec(value)?.[1] ?? // in the 3-digit form each digit is doubled: #f0a means #ff00aa
    /^#([0-9a-f]{3})$/iu
      .exec(value)?.[1]
      ?.split("")
      .map((digit) => digit + digit)
      .join("");
  if (digits === undefined) return null;

  return [digits.substring(0, 2), digits.substring(2, 4), digits.substring(4, 6)].map((channel) =>
    parseInt(channel, 16),
  );
};

export const hexToRgb = (hex: string) => (parseHex(hex) ?? [0, 0, 0]).join(" ");

const toHex = (rgb: number[]) => `#${rgb.map((channel) => channel.toString(16).padStart(2, "0")).join("")}`;

// WCAG relative luminance: how bright a colour actually looks, on a 0 (black) to 1 (white) scale.
// Each channel is un-gamma-corrected and then weighted, because the eye is far more sensitive to
// green than to blue — green carries roughly 72% of perceived brightness, blue only about 7%.
// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
const relativeLuminance = (rgb: number[]) => {
  const [r, g, b] = rgb.map((channel) => {
    const value = channel / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });

  return 0.2126 * (r ?? 0) + 0.7152 * (g ?? 0) + 0.0722 * (b ?? 0);
};

// https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
const contrastRatio = (luminance: number, otherLuminance: number) =>
  (Math.max(luminance, otherLuminance) + 0.05) / (Math.min(luminance, otherLuminance) + 0.05);

const ratioBetween = (rgb: number[], otherRgb: number[]) =>
  contrastRatio(relativeLuminance(rgb), relativeLuminance(otherRgb));

// APCA's own luminance measure. Same idea as WCAG relative luminance but with a simple 2.4-power
// curve per channel and a soft clamp near black, which is what makes it track perceived readability
// on very dark colours.
const apcaScreenLuminance = (rgb: number[]) => {
  const [r, g, b] = rgb.map((channel) => (channel / 255) ** 2.4);
  const y = 0.2126729 * (r ?? 0) + 0.7151522 * (g ?? 0) + 0.072175 * (b ?? 0);

  return y < 0.022 ? y + (0.022 - y) ** 1.414 : y;
};

// APCA lightness contrast (Lc), as a signed score: positive for dark text on a light background and
// negative for light text on a dark background. Unlike the WCAG 2 ratio it is asymmetric. We use
// only its magnitude to rank black against white; WCAG 2.2 compliance still comes from the 4.5:1
// floor below. Constants and clipping match APCA 0.1.9.
// https://github.com/Myndex/SAPC-APCA
const apcaLc = (textRgb: number[], backgroundRgb: number[]) => {
  const textY = apcaScreenLuminance(textRgb);
  const backgroundY = apcaScreenLuminance(backgroundRgb);
  if (Math.abs(backgroundY - textY) < 0.0005) return 0;

  if (backgroundY > textY) {
    const contrast = (backgroundY ** 0.56 - textY ** 0.57) * 1.14;
    return contrast < 0.1 ? 0 : (contrast - 0.027) * 100;
  }

  const contrast = (backgroundY ** 0.65 - textY ** 0.62) * 1.14;
  return contrast > -0.1 ? 0 : (contrast + 0.027) * 100;
};

// Mixes the colour `step`/255 of the way toward black (when the text will be white) or toward white
// (when the text will be black). Math.floor rather than rounding because the Ruby implementation has
// to land on the identical byte and the two languages round halves differently.
const shiftBrightness = (rgb: number[], whiteText: boolean, step: number) => {
  const target = whiteText ? 0 : 255;
  return rgb.map((channel) => Math.floor(channel + ((target - channel) * step) / 255));
};

// Smallest number of 0-255 steps toward black (for white text) or toward white (for black text) that
// brings the pair to the WCAG AA floor. Binary search is safe because mixing steadily toward black
// or white moves the contrast ratio in one direction only.
const brightnessShiftFor = (rgb: number[], whiteText: boolean) => {
  const text = whiteText ? [255, 255, 255] : [0, 0, 0];
  if (ratioBetween(rgb, text) >= WCAG_AA_NORMAL_TEXT) return 0;

  let low = 0;
  let high = 255;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (ratioBetween(shiftBrightness(rgb, whiteText, middle), text) >= WCAG_AA_NORMAL_TEXT) high = middle;
    else low = middle + 1;
  }

  return low;
};

/**
 * Picks black or white — whichever is actually more readable on top of the given colour.
 *
 * This used to test HSL lightness against a 55% cutoff, but HSL lightness is just
 * (max + min) / 2 of the raw red/green/blue channels, with no weighting for how bright a colour
 * looks to a human. That made a bright green accent read as "dark" and get white text on top of
 * it at 1.37:1 contrast, which is effectively invisible. Comparing real contrast ratios instead
 * removes the threshold entirely.
 *
 * Used where the colour underneath cannot be adjusted: the storefront background, and body text.
 * For accent areas that contain text, use getAccessibleAccent instead.
 *
 * This must stay in step with ContrastColor.for in lib/utilities/contrast_color.rb — the server
 * renders the live storefront CSS and this renders the editor preview, so if the two disagree a
 * seller sees one colour while setting up and a different one on their actual store.
 */
export const getContrastColor = (background: string) => {
  const rgb = parseHex(background);
  if (rgb === null) return "#000000";

  const luminance = relativeLuminance(rgb);

  return contrastRatio(luminance, 1) > contrastRatio(luminance, 0) ? "#FFFFFF" : "#000000";
};

/**
 * Mixes a hex colour `step`/255 of the way toward black (for white text) or toward white (for black
 * text). Exported only so a test can show the chosen step is minimal by checking the step below it
 * fails; production code should call getAccessibleAccent.
 */
export const shiftAccentBrightness = (hex: string, whiteText: boolean, step: number) => {
  const rgb = parseHex(hex);
  return rgb === null ? null : toHex(shiftBrightness(rgb, whiteText, step));
};

/** The smallest step getAccessibleAccent would use for this text colour. Exported for the same reason. */
export const accentBrightnessShiftFor = (hex: string, whiteText: boolean) => {
  const rgb = parseHex(hex);
  return rgb === null ? null : brightnessShiftFor(rgb, whiteText);
};

/**
 * Returns the pair to actually render for an accent area that contains text: the accent colour to
 * fill with, and the text colour to put on it.
 *
 * `accent` is the seller's colour with its brightness nudged if — and only if — that was needed to
 * clear 4.5:1. What the seller saved is never modified; this is a display-time adjustment.
 *
 * Why the simple "whichever of black or white contrasts more" rule isn't enough here: on a
 * saturated warm hue the two candidates land close together on opposite sides of a hard flip. Pure
 * red #ff0000 scores 4.00:1 with white and 5.25:1 with black, so black wins — yet three hex steps
 * away at #ec0000 the winner is white, and the two reds are indistinguishable to the eye. Sellers
 * with a red accent saw the price on their pay button go black, which reads as broken even though it
 * is technically the higher-contrast option. The flip is arbitrary: it sits wherever the two ratios
 * happen to cross.
 *
 * So we ask a better question in three steps.
 *
 * 1. Which text colour looks more readable? APCA is used as a non-normative perceptual ranking.
 *    It says white on pure red, which is what sellers expect.
 * 2. Does that pair clear the 4.5:1 WCAG AA floor? White on #ff0000 does not (4.00:1). If it
 *    doesn't, darken the accent for white text (or lighten it for black text) by the smallest amount
 *    that does. #ff0000 becomes #ee0000 — same red to the eye, now 4.53:1 with white.
 * 3. If APCA rates black and white within APCA_TIE_BAND of each other, neither has a strong
 *    perceptual lead, so use the one that changes the creator's colour less. Outside that tie,
 *    honour APCA and apply exactly the minimum WCAG adjustment.
 *
 * The floor in step 2 is never traded away, and the surrounding page background is deliberately not
 * an input — the same accent has to work on light and dark storefronts alike.
 *
 * Keep this in step with ContrastColor.accessible_accent in lib/utilities/contrast_color.rb. The
 * shared fixture in spec/fixtures/accent_contrast_pairs.json is asserted by both test suites for
 * exactly that reason.
 */
export const getAccessibleAccent = (accent: string): { accent: string; text: string } => {
  const rgb = parseHex(accent);
  if (rgb === null) return { accent: BLACK, text: WHITE };

  const apcaWithWhite = Math.abs(apcaLc([255, 255, 255], rgb));
  const apcaWithBlack = Math.abs(apcaLc([0, 0, 0], rgb));
  let whiteText = apcaWithWhite > apcaWithBlack;
  let displayShift = brightnessShiftFor(rgb, whiteText);
  const otherShift = brightnessShiftFor(rgb, !whiteText);

  if (otherShift < displayShift && Math.abs(apcaWithWhite - apcaWithBlack) <= APCA_TIE_BAND) {
    whiteText = !whiteText;
    displayShift = otherShift;
  }

  return {
    accent: toHex(shiftBrightness(rgb, whiteText, displayShift)),
    text: whiteText ? WHITE : BLACK,
  };
};

/** WCAG contrast ratio between two hex colours, e.g. 15.36 for black on bright green. */
export const getContrastRatio = (hex: string, otherHex: string) => {
  const rgb = parseHex(hex);
  const otherRgb = parseHex(otherHex);
  if (rgb === null || otherRgb === null) return null;

  return ratioBetween(rgb, otherRgb);
};
