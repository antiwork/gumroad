// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { LoggedInUserProvider } from "$app/components/LoggedInUser";
import { Thumbnail } from "$app/components/Product/Thumbnail";

afterEach(cleanup);

const renderThumbnail = (props: React.ComponentProps<typeof Thumbnail>) =>
  render(
    <LoggedInUserProvider value={null}>
      <Thumbnail {...props} />
    </LoggedInUserProvider>,
  );

describe("Thumbnail", () => {
  // `alt=""` and a missing `alt` render identically and both read as "no description", so these
  // assert on hasAttribute rather than the value: the attribute's presence is the whole fix. Without
  // it assistive technology announces the filename or URL instead of skipping the image.
  it("marks an uploaded thumbnail as decorative", () => {
    const { container } = renderThumbnail({ url: "https://example.com/cover.png", nativeType: "digital" });

    const img = container.querySelector("img");
    expect(img).not.toBeNull();
    expect(img?.hasAttribute("alt")).toBe(true);
    expect(img?.getAttribute("alt")).toBe("");
  });

  it("marks the native-type fallback as decorative", () => {
    const { container } = renderThumbnail({ url: null, nativeType: "digital" });

    const img = container.querySelector("img");
    expect(img).not.toBeNull();
    expect(img?.hasAttribute("alt")).toBe(true);
    expect(img?.getAttribute("alt")).toBe("");
  });
});
