export const hexToRgb = (hex: string) =>
  `${parseInt(hex.slice(1, 3), 16)} ${parseInt(hex.slice(3, 5), 16)} ${parseInt(hex.slice(5), 16)}`;

// WCAG relative luminance: how bright a colour actually looks, on a 0 (black) to 1 (white) scale.
// Each channel is un-gamma-corrected and then weighted, because the eye is far more sensitive to
// green than to blue — green carries roughly 72% of perceived brightness, blue only about 7%.
// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
const relativeLuminance = (hex: string) => {
  const channels = [hex.substring(1, 3), hex.substring(3, 5), hex.substring(5, 7)].map((channel) => {
    const value = parseInt(channel, 16) / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });

  return 0.2126 * (channels[0] ?? 0) + 0.7152 * (channels[1] ?? 0) + 0.0722 * (channels[2] ?? 0);
};

// https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio
const contrastRatio = (luminance: number, otherLuminance: number) =>
  (Math.max(luminance, otherLuminance) + 0.05) / (Math.min(luminance, otherLuminance) + 0.05);

/**
 * Picks black or white — whichever is actually more readable on top of the given colour.
 *
 * This used to test HSL lightness against a 55% cutoff, but HSL lightness is just
 * (max + min) / 2 of the raw red/green/blue channels, with no weighting for how bright a colour
 * looks to a human. That made a bright green accent read as "dark" and get white text on top of
 * it at 1.37:1 contrast, which is effectively invisible. Comparing real contrast ratios instead
 * removes the threshold entirely.
 *
 * This must stay in step with ContrastColor in lib/utilities/contrast_color.rb — the server
 * renders the live storefront CSS and this renders the editor preview, so if the two disagree a
 * seller sees one colour while setting up and a different one on their actual store.
 */
export const getContrastColor = (background: string) => {
  const luminance = relativeLuminance(background);

  return contrastRatio(luminance, 1) > contrastRatio(luminance, 0) ? "#FFFFFF" : "#000000";
};
