// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Button } from "$app/components/Button";

afterEach(cleanup);

describe("Button brand colors", () => {
  // The YouTube connect and disconnect buttons sit directly beside the X buttons in
  // Settings > Profile > Social links, so both rows have to read as the same control. Comparing
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
});
