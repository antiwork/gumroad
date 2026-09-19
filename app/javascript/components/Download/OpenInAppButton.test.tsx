// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { OpenInAppButton } from "$app/components/Download/OpenInAppButton";

afterEach(cleanup);

describe("OpenInAppButton", () => {
  it("paints the store badges with the brand color rather than the default transparent pair", async () => {
    render(
      <OpenInAppButton
        iosAppUrl="https://apps.apple.com/app/id1"
        androidAppUrl="https://play.google.com/details?id=1"
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Open in app" }));

    const appStore = await screen.findByRole("link", { name: "App Store" });
    expect(appStore.className).toContain("bg-black");
    expect(appStore.className).toContain("text-white");

    const playStore = screen.getByRole("link", { name: "Play Store" });
    expect(playStore.className).toContain("bg-[#142f40]");
    expect(playStore.className).toContain("text-white");

    // `asChild` hands the Button's classes to the anchor through Radix Slot, which concatenates
    // without deduping: applying the color to the child instead of the Button leaves the default
    // transparent pair on the anchor, and CSS order then wins over the brand color.
    for (const anchor of [appStore, playStore]) {
      expect(anchor.className).not.toContain("bg-transparent");
      expect(anchor.className).not.toContain("text-current");
    }
  });
});
