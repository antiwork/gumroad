// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Button } from "$app/components/Button";

afterEach(cleanup);

describe("Button brand colors", () => {
  // The YouTube connect and disconnect buttons sit directly beside the X buttons in
  // Settings > Social connections, so both rows have to read as the same control. Comparing
  // against the X button, instead of only asserting bg-black, is what catches a switch back to a
  // provider brand fill such as Google's blue.
  it("fills the YouTube button like the X button", () => {
    render(
      <>
        <Button color="twitter">Connect to X</Button>
        <Button color="youtube">Connect to YouTube</Button>
      </>,
    );

    const x = screen.getByRole("button", { name: "Connect to X" });
    const youtube = screen.getByRole("button", { name: "Connect to YouTube" });

    expect(youtube.className).toBe(x.className);
    expect(youtube.className).toContain("bg-black");
  });

  it("fills the Instagram button like the X button", () => {
    render(
      <>
        <Button color="twitter">Connect to X</Button>
        <Button color="instagram">Connect to Instagram</Button>
      </>,
    );

    const x = screen.getByRole("button", { name: "Connect to X" });
    const instagram = screen.getByRole("button", { name: "Connect to Instagram" });

    expect(instagram.className).toBe(x.className);
    expect(instagram.className).toContain("bg-black");
  });

  it("fills the TikTok button like the X button", () => {
    render(
      <>
        <Button color="twitter">Connect to X</Button>
        <Button color="tiktok">Connect to TikTok</Button>
      </>,
    );

    const x = screen.getByRole("button", { name: "Connect to X" });
    const tiktok = screen.getByRole("button", { name: "Connect to TikTok" });

    expect(tiktok.className).toBe(x.className);
    expect(tiktok.className).toContain("bg-black");
  });
});

describe("Button hover halo", () => {
  const offsets = (className: string, prefixes: string[]) =>
    prefixes.map((prefix) => {
      const token = className.split(" ").find((name) => name.startsWith(prefix));

      return token?.match(/\((--[\w-]+)\)/u)?.[1];
    });

  // A pointer resting on the right or bottom edge is outside the lifted button, so the halo has to
  // grow by exactly the offset the lift moves or the hover flickers again.
  it("grows the hover halo by the offset the lift moves", () => {
    render(<Button color="primary">Buy</Button>);

    const button = screen.getByRole("button", { name: "Buy" });

    expect(offsets(button.className, ["hover:-translate-", "[--lift-halo-offset:"])).toEqual([
      "--button-hover-offset",
      "--button-hover-offset",
    ]);
  });

  // A halo is applied bare because a `hover:` prefix would take `contain: layout` off with it, and
  // that would re-anchor the halo to a caller's own positioning.
  it("holds the halo's anchor still", () => {
    render(<Button>Buy</Button>);

    const button = screen.getByRole("button", { name: "Buy" });

    expect(button.className.split(" ")).toContain("lift-halo");
    expect(button.className).not.toMatch(/hover:lift-halo|after:/u);
  });

  // A halo anchored to an ancestor instead of the button would cover that ancestor and swallow its
  // clicks, so the anchor cannot be a `position` that a caller's own className overrides.
  it("anchors the halo to the button without moving a caller's own positioning", () => {
    render(<Button className="absolute top-2 right-2">Remove icon</Button>);

    const button = screen.getByRole("button", { name: "Remove icon" });

    expect(button.className.split(" ")).toContain("lift-halo");
    expect(button.className).not.toMatch(/(^|\s)relative(\s|$)/u);
    expect(button.className).toContain("absolute");
  });
});
