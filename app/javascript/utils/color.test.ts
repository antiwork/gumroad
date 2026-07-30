import { describe, it, expect } from "vitest";

import {
  WCAG_AA_NON_TEXT,
  WCAG_AA_NORMAL_TEXT,
  accentBrightnessShiftFor,
  getAccessibleAccent,
  getContrastColor,
  getContrastRatio,
  getVisibleIndicator,
  hexToRgb,
  rgbToHex,
  shiftAccentBrightness,
} from "$app/utils/color";

// The shared server/browser fixture. It lives under spec/ because the Ruby suite asserts the same
// file — see the "matches the server implementation" test below.
import accentContrastPairs from "../../../spec/fixtures/accent_contrast_pairs.json";
import indicatorContrastPairs from "../../../spec/fixtures/indicator_contrast_pairs.json";

describe("getContrastColor", () => {
  it("picks black on a bright accent that HSL lightness misjudged as dark", () => {
    // The bug this function was rewritten for. #19ff1d sits at 54.9% HSL lightness, just under the
    // old 55% cutoff, so it used to get white text at 1.37:1 contrast. Black is 15.36:1.
    expect(getContrastColor("#19ff1d")).toBe("#000000");
  });

  it("still picks white on genuinely dark colours", () => {
    expect(getContrastColor("#000000")).toBe("#FFFFFF");
    expect(getContrastColor("#0a0a0a")).toBe("#FFFFFF");
  });

  it("still picks black on genuinely light colours", () => {
    expect(getContrastColor("#ffffff")).toBe("#000000");
    expect(getContrastColor("#ff90e8")).toBe("#000000");
  });

  it("does not depend on which side of a lightness threshold a colour falls", () => {
    // These two are visually identical but land on opposite sides of the old cutoff, which is why
    // support once had to nudge a seller's colour by a single hex step as a workaround.
    expect(getContrastColor("#19ff1d")).toBe(getContrastColor("#1aff1e"));
  });

  it("handles the 3-digit hex form the same way as its 6-digit equivalent", () => {
    // The stored colour is only validated on ordinary saves, so a 3-digit value can reach this.
    // Treating it as invalid would put black text on a black background.
    expect(getContrastColor("#000")).toBe(getContrastColor("#000000"));
    expect(getContrastColor("#fff")).toBe(getContrastColor("#ffffff"));
    expect(getContrastColor("#f0a")).toBe(getContrastColor("#ff00aa"));
  });

  it("is case insensitive and tolerates surrounding whitespace", () => {
    expect(getContrastColor("#19FF1D")).toBe("#000000");
    expect(getContrastColor("  #0a0a0a  ")).toBe("#FFFFFF");
  });

  it("falls back to black rather than throwing on a value that isn't a hex colour", () => {
    for (const invalid of ["", "red", "#ffff", "#gggggg", "#19ff1d; }", "#000000\nX"]) {
      expect(getContrastColor(invalid)).toBe("#000000");
    }
  });

  // This is the guarantee the server-side ContrastColor module is built around: whichever of black
  // or white contrasts more is always at least 4.58:1, comfortably above the WCAG AA minimum of
  // 4.5:1 for normal-size text. So no colour a seller can pick yields unreadable text.
  it("never produces text below the WCAG AA minimum, for any colour a seller can pick", () => {
    const relativeLuminance = (hex: string) => {
      const channels = [hex.substring(1, 3), hex.substring(3, 5), hex.substring(5, 7)].map((channel) => {
        const value = parseInt(channel, 16) / 255;
        return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
      });
      return 0.2126 * (channels[0] ?? 0) + 0.7152 * (channels[1] ?? 0) + 0.0722 * (channels[2] ?? 0);
    };
    const ratio = (a: number, b: number) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);

    let worst = Infinity;
    let worstColor = "";

    for (let r = 0; r < 256; r += 15) {
      for (let g = 0; g < 256; g += 15) {
        for (let b = 0; b < 256; b += 15) {
          const color = `#${[r, g, b].map((c) => c.toString(16).padStart(2, "0")).join("")}`;
          const chosen = getContrastColor(color);
          const contrast = ratio(relativeLuminance(color), chosen === "#FFFFFF" ? 1 : 0);
          if (contrast < worst) {
            worst = contrast;
            worstColor = color;
          }
        }
      }
    }

    expect(worst, `${worstColor} only reaches ${worst.toFixed(2)}:1`).toBeGreaterThanOrEqual(4.5);
  });
});

describe("hexToRgb", () => {
  it("converts a hex colour to space-separated channel values for use in a CSS rgb()", () => {
    expect(hexToRgb("#19ff1d")).toBe("25 255 29");
    expect(hexToRgb("#000000")).toBe("0 0 0");
    expect(hexToRgb("#f0a")).toBe("255 0 170");
    expect(hexToRgb("  #19FF1D  ")).toBe("25 255 29");
    expect(hexToRgb("not a colour")).toBe("0 0 0");
  });
});

describe("getAccessibleAccent", () => {
  const ratio = (pair: { accent: string; text: string }) => getContrastRatio(pair.accent, pair.text) ?? 0;

  it("gives a saturated red pay button white text, by darkening the displayed red slightly", () => {
    // The bug this function exists to fix. On #ff0000 black's WCAG ratio (5.25:1) marginally beats
    // white's (4.00:1), so the plain two-way comparison picked black — which sellers read as broken.
    // APCA agrees with them that white is the readable choice, and darkening the red slightly gets
    // white over the 4.5:1 line.
    const pair = getAccessibleAccent("#ff0000");

    expect(pair.text).toBe("#ffffff");
    expect(pair.accent).toBe("#ee0000");
    expect(ratio(pair)).toBeGreaterThanOrEqual(WCAG_AA_NORMAL_TEXT);
  });

  it("picks black on bright green and on orange", () => {
    // The population the previous fix was for: white on these is invisible (1.37:1 and 1.54:1).
    expect(getAccessibleAccent("#19ff1d")).toStrictEqual({ accent: "#19ff1d", text: "#000000" });
    expect(getAccessibleAccent("#ffc900")).toStrictEqual({ accent: "#ffc900", text: "#000000" });
  });

  it("picks white on a saturated blue", () => {
    expect(getAccessibleAccent("#0000ff")).toStrictEqual({ accent: "#0000ff", text: "#ffffff" });
    expect(getAccessibleAccent("#1a4bff")).toStrictEqual({ accent: "#1a4bff", text: "#ffffff" });
  });

  it("leaves the accent untouched whenever the preferred text colour already clears the floor", () => {
    for (const hex of ["#19ff1d", "#ffc900", "#0000ff", "#ff90e8", "#ffffff", "#000000", "#767676", "#ec0000"]) {
      expect(getAccessibleAccent(hex).accent, `${hex} should be displayed unchanged`).toBe(hex);
    }
  });

  it("changes every adjusted example by the smallest amount that clears the floor", () => {
    // Provably minimal rather than merely sufficient: the step below the one chosen must fail. Uses
    // the same mixing function the implementation uses, so "one step less" is genuinely the candidate
    // the search rejected rather than a nearby colour that happens to fail.
    for (const hex of ["#ff0000", "#009a49", "#ff3f00", "#ff00ff", "#23a094"]) {
      const pair = getAccessibleAccent(hex);
      const whiteText = pair.text === "#ffffff";
      const chosenStep = accentBrightnessShiftFor(hex, whiteText) ?? 0;

      expect(chosenStep, `${hex} needed no adjustment, so this case proves nothing`).toBeGreaterThan(0);
      expect(pair.accent).toBe(shiftAccentBrightness(hex, whiteText, chosenStep));
      expect(ratio(pair)).toBeGreaterThanOrEqual(WCAG_AA_NORMAL_TEXT);

      const oneStepLess = shiftAccentBrightness(hex, whiteText, chosenStep - 1) ?? "";
      expect(
        getContrastRatio(oneStepLess, pair.text) ?? 0,
        `${oneStepLess} already passes, so ${pair.accent} is not minimal for ${hex}`,
      ).toBeLessThan(WCAG_AA_NORMAL_TEXT);
    }
  });

  it("never returns a pair below the WCAG AA minimum", () => {
    let worstRatio = Infinity;
    let worstRatioColor = "";

    for (let r = 0; r < 256; r += 15) {
      for (let g = 0; g < 256; g += 15) {
        for (let b = 0; b < 256; b += 15) {
          const color = `#${[r, g, b].map((c) => c.toString(16).padStart(2, "0")).join("")}`;
          const pair = getAccessibleAccent(color);
          const contrast = ratio(pair);
          if (contrast < worstRatio) {
            worstRatio = contrast;
            worstRatioColor = color;
          }
        }
      }
    }

    expect(worstRatio, `${worstRatioColor} only reaches ${worstRatio.toFixed(2)}:1`).toBeGreaterThanOrEqual(
      WCAG_AA_NORMAL_TEXT,
    );
  });

  it("resolves visually identical colours identically", () => {
    // The failure mode this replaces: #ec0000 and #ed0000 are the same red to the eye but landed on
    // opposite sides of the crossover, so one got white text and the other black.
    for (const hex of ["#eb0000", "#ec0000", "#ed0000", "#ee0000", "#ef0000", "#f00000"]) {
      expect(getAccessibleAccent(hex).text, `${hex} did not get white text`).toBe("#ffffff");
    }
  });

  it("does not flip polarity or add a needless adjustment at the old cost boundary", () => {
    // These saved colours differ by one green-channel step. Both keep APCA's white text and receive
    // exactly the minimum WCAG adjustment; there is no cost cap or taper to change the answer.
    const before = getAccessibleAccent("#ff3e00");
    const after = getAccessibleAccent("#ff3f00");

    expect(before).toStrictEqual({ accent: "#df3600", text: "#ffffff" });
    expect(after).toStrictEqual({ accent: "#de3600", text: "#ffffff" });
    expect(ratio(before)).toBeGreaterThanOrEqual(WCAG_AA_NORMAL_TEXT);
    expect(ratio(after)).toBeGreaterThanOrEqual(WCAG_AA_NORMAL_TEXT);

    const beforeRgb = before.accent.match(/[0-9a-f]{2}/giu)?.map((channel) => parseInt(channel, 16)) ?? [];
    const afterRgb = after.accent.match(/[0-9a-f]{2}/giu)?.map((channel) => parseInt(channel, 16)) ?? [];
    expect(Math.max(...beforeRgb.map((channel, index) => Math.abs(channel - (afterRgb[index] ?? 0))))).toBe(1);
  });

  it("preserves the saved colour when APCA has no strong polarity preference", () => {
    expect(getAccessibleAccent("#78aac0")).toStrictEqual({ accent: "#78aac0", text: "#000000" });
  });

  it("handles the 3-digit hex form the same way as its 6-digit equivalent", () => {
    expect(getAccessibleAccent("#f0a")).toStrictEqual(getAccessibleAccent("#ff00aa"));
    expect(getAccessibleAccent("#000")).toStrictEqual(getAccessibleAccent("#000000"));
  });

  it("moves the contrast ratio in one direction only, so the search's answer is the minimum", () => {
    // The binary search assumes monotonicity: mixing steadily toward black (with white text) or
    // toward white (with black text) only ever increases contrast against that text colour. Channel
    // flooring could in principle break that, so walk every step on colours spanning the space.
    for (const hex of ["#ff0000", "#009a49", "#0087ff", "#7b2ff7", "#123456", "#abcdef"]) {
      for (const whiteText of [true, false]) {
        const text = whiteText ? "#ffffff" : "#000000";
        const ratios = Array.from(
          { length: 256 },
          (_, step) => getContrastRatio(shiftAccentBrightness(hex, whiteText, step) ?? "", text) ?? 0,
        );
        const drops = ratios
          .slice(1)
          .map((after, index) => ({ before: ratios[index] ?? 0, after }))
          .filter(({ before, after }) => after < before - 1e-9);

        expect(drops, `${hex} with ${text} text is not monotone`).toHaveLength(0);
      }
    }
  });

  it("trims exactly the whitespace the server implementation trims", () => {
    // Ruby's String#strip removes only ASCII whitespace, so contrast_color.rb strips this same
    // character class explicitly. A disagreement means a stored value carrying a non-breaking space
    // or byte-order mark parses here and falls back to the default on the live storefront.
    const javascriptTrimCharacters = [
      "\u0009",
      "\u000a",
      "\u000b",
      "\u000c",
      "\u000d",
      "\u0020",
      "\u00a0",
      "\u1680",
      "\u2000",
      "\u2009",
      "\u2028",
      "\u2029",
      "\u202f",
      "\u205f",
      "\u3000",
      "\ufeff",
    ];

    for (const character of javascriptTrimCharacters) {
      expect(
        getAccessibleAccent(`${character}#ff0000${character}`),
        `U+${character.charCodeAt(0).toString(16).padStart(4, "0")} was not trimmed`,
      ).toStrictEqual({ accent: "#ee0000", text: "#ffffff" });
    }
  });

  it("falls back to a readable pair rather than throwing on a value that isn't a hex colour", () => {
    for (const invalid of ["", "red", "#ffff", "#gggggg", "#19ff1d; }", "\u0085#ff0000\u0085"]) {
      expect(getAccessibleAccent(invalid)).toStrictEqual({ accent: "#000000", text: "#ffffff" });
    }
  });

  it("matches the server implementation on every colour in the shared fixture", () => {
    // lib/utilities/contrast_color.rb renders the live storefront CSS while this renders the editor
    // preview, so any divergence shows a seller one colour while setting up and another on their
    // store. The fixture was generated from the Ruby side, which is what makes THIS half the
    // load-bearing one: it holds the browser to the server's answers. contrast_color_spec.rb asserts
    // the same file so a Ruby change cannot quietly rewrite the contract instead.
    expect(accentContrastPairs.length).toBeGreaterThanOrEqual(40);
    for (const expected of accentContrastPairs) {
      expect(getAccessibleAccent(expected.input), `pair for ${expected.input}`).toStrictEqual({
        accent: expected.accent,
        text: expected.text,
      });
    }
  });
});

describe("rgbToHex", () => {
  it("round-trips both the space- and comma-joined forms a CSS custom property can hold", () => {
    expect(rgbToHex("255 144 232")).toBe("#ff90e8");
    expect(rgbToHex("255,144,232")).toBe("#ff90e8");
    expect(rgbToHex("  0 0 0  ")).toBe("#000000");
    expect(rgbToHex(hexToRgb("#19ff1d"))).toBe("#19ff1d");
  });

  it("degrades to black rather than raising on anything that isn't three 0-255 channels", () => {
    for (const invalid of ["", "255 144", "255 144 232 1", "255 144 300", "-1 0 0", "a b c", "1.5 2 3"]) {
      expect(rgbToHex(invalid), `for ${JSON.stringify(invalid)}`).toBe("#000000");
    }
  });
});

describe("getVisibleIndicator", () => {
  it("leaves a colour that already clears the non-text floor untouched", () => {
    // The stock pink on the dark neutral background: 10.41:1, nothing to fix.
    expect(getVisibleIndicator("#ff90e8", "#000000")).toBe("#ff90e8");
    expect(getVisibleIndicator("#009a49", "#f8efe3")).toBe("#009a49");
  });

  it("darkens on a light background and lightens on a dark one, keeping the hue", () => {
    expect(getVisibleIndicator("#ff90e8", "#ffffff")).toBe("#d075bd");
    expect(getVisibleIndicator("#111111", "#000000")).toBe("#5a5a5a");
  });

  it("shifts by the smallest amount that clears the floor", () => {
    const indicator = getVisibleIndicator("#ff90e8", "#ffffff");
    expect(getContrastRatio(indicator, "#ffffff")).toBeGreaterThanOrEqual(WCAG_AA_NON_TEXT);
    expect(getContrastRatio(indicator, "#ffffff")).toBeLessThan(WCAG_AA_NON_TEXT + 0.05);
  });

  it("rescues a colour identical to its background", () => {
    for (const color of ["#ffffff", "#f8efe3", "#000000"]) {
      expect(getContrastRatio(getVisibleIndicator(color, color), color), `${color} on itself`).toBeGreaterThanOrEqual(
        WCAG_AA_NON_TEXT,
      );
    }
  });

  it("falls back to black rather than raising on a value that isn't a hex colour", () => {
    expect(getVisibleIndicator("red", "#ffffff")).toBe("#000000");
    expect(getVisibleIndicator("#ff90e8", "not-a-colour")).toBe("#000000");
  });

  it("reads a legacy three-digit value the same as its six-digit equivalent", () => {
    expect(getVisibleIndicator("#f0a", "#fff")).toBe(getVisibleIndicator("#ff00aa", "#ffffff"));
  });

  it("matches the server implementation on every pair in the shared fixture", () => {
    // ContrastColor.visible_indicator floors the seller's saved indicator server-side while this
    // floors the neutral checkout palette in the browser. The fixture was generated from the Ruby
    // side, so this half holds the browser to the server's answers; contrast_color_spec.rb asserts
    // the same file, which stops a Ruby change from quietly rewriting the contract instead.
    expect(indicatorContrastPairs.length).toBeGreaterThanOrEqual(40);
    for (const expected of indicatorContrastPairs) {
      expect(
        getVisibleIndicator(expected.input, expected.background),
        `${expected.input} on ${expected.background}`,
      ).toBe(expected.indicator);
    }
  });
});
