export const hexToRgb = (hex: string) =>
  `${parseInt(hex.slice(1, 3), 16)} ${parseInt(hex.slice(3, 5), 16)} ${parseInt(hex.slice(5), 16)}`;

// WCAG AA requires 4.5:1 for normal-size text. This is a hard floor: no accent/text pair we render
// is ever allowed below it.
export const WCAG_AA_NORMAL_TEXT = 4.5;

// How close the two APCA readability scores have to be before we stop trusting the winner and break
// the tie on "which choice needs the accent changed least".
const APCA_TIE_BAND = 10;

// If the more readable text colour would force us to move the accent's brightness by more than this
// many 0-255 steps, and the other text colour needs a smaller move, take the other one.
const MAX_BRIGHTNESS_SHIFT = 32;

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

// APCA lightness contrast (Lc), as an absolute 0-106ish score: how readable text of one colour is on
// a background of another. Unlike the WCAG 2 ratio it is asymmetric — dark-on-light and light-on-dark
// are scored with different exponents, which is the whole reason it agrees with the eye on saturated
// hues where the WCAG ratio does not. Constants are from the APCA 0.1.9 formula.
// https://github.com/Myndex/SAPC-APCA
const apcaLc = (textRgb: number[], backgroundRgb: number[]) => {
  const textY = apcaScreenLuminance(textRgb);
  const backgroundY = apcaScreenLuminance(backgroundRgb);
  if (Math.abs(backgroundY - textY) < 0.0005) return 0;

  const contrast =
    backgroundY > textY
      ? (backgroundY ** 0.56 - textY ** 0.57) * 1.14 // dark text on a lighter background
      : (backgroundY ** 0.65 - textY ** 0.62) * 1.14; // light text on a darker background

  // Near-zero contrast is clamped to 0 and low contrast is scaled down, so that trivially different
  // colours don't report a misleadingly usable score.
  let scaled;
  if (Math.abs(contrast) < 0.001) scaled = 0;
  else if (Math.abs(contrast) > 0.035991) scaled = contrast - (contrast > 0 ? 0.027 : -0.027);
  else scaled = contrast * 27.7847239587675;

  return Math.abs(scaled * 100);
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
 * 1. Which text colour looks more readable? That is judged with APCA (the perceptual contrast model
 *    being developed for WCAG 3), because it models how text of a given lightness reads on a
 *    background far better than the WCAG 2 ratio does. APCA says white on pure red, which is what a
 *    designer would choose and what sellers expect.
 * 2. Does that pair clear the 4.5:1 WCAG AA floor? White on #ff0000 does not (4.00:1). If it
 *    doesn't, darken the accent for white text (or lighten it for black text) by the smallest amount
 *    that does. #ff0000 becomes #ee0000 — same red to the eye, now 4.53:1 with white.
 * 3. Sanity-check the choice against its cost. If the two APCA scores are within APCA_TIE_BAND of
 *    each other, or if honouring the winner would move the accent by more than MAX_BRIGHTNESS_SHIFT
 *    steps, and the other text colour needs a smaller move, use the other one instead.
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

  const apcaWithWhite = apcaLc([255, 255, 255], rgb);
  const apcaWithBlack = apcaLc([0, 0, 0], rgb);
  let whiteText = apcaWithWhite > apcaWithBlack;

  const shiftForWhite = brightnessShiftFor(rgb, true);
  const shiftForBlack = brightnessShiftFor(rgb, false);
  let chosenShift = whiteText ? shiftForWhite : shiftForBlack;
  const otherShift = whiteText ? shiftForBlack : shiftForWhite;

  if (
    otherShift < chosenShift &&
    (Math.abs(apcaWithWhite - apcaWithBlack) <= APCA_TIE_BAND || chosenShift > MAX_BRIGHTNESS_SHIFT)
  ) {
    whiteText = !whiteText;
    chosenShift = otherShift;
  }

  return { accent: toHex(shiftBrightness(rgb, whiteText, chosenShift)), text: whiteText ? WHITE : BLACK };
};

/** WCAG contrast ratio between two hex colours, e.g. 15.36 for black on bright green. */
export const getContrastRatio = (hex: string, otherHex: string) => {
  const rgb = parseHex(hex);
  const otherRgb = parseHex(otherHex);
  if (rgb === null || otherRgb === null) return null;

  return ratioBetween(rgb, otherRgb);
};
