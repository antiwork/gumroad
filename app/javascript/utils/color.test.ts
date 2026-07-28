import { describe, it, expect } from "vitest";

import { getContrastColor, hexToRgb } from "$app/utils/color";

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
  });
});
