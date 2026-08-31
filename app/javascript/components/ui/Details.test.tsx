// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Details, DetailsToggle } from "$app/components/ui/Details";

afterEach(cleanup);

const chevron = () => {
  const svg = document.querySelector("summary svg");
  if (!svg) throw new Error("expected a chevron svg");
  return svg;
};

describe("DetailsToggle", () => {
  it("rotates one chevron when opened instead of swapping icons", () => {
    render(
      <Details>
        <DetailsToggle>More options</DetailsToggle>
        <p>Hidden until open</p>
      </Details>,
    );

    const closed = chevron();
    expect(closed.classList.contains("rotate-90")).toBe(false);
    expect(closed.classList.contains("transition-transform")).toBe(true);

    fireEvent.click(screen.getByText("More options"));

    const open = chevron();
    expect(open.classList.contains("rotate-90")).toBe(true);
    expect(document.querySelectorAll("summary svg")).toHaveLength(1);
  });

  it("hides the chevron when chevronPosition is none", () => {
    render(
      <Details>
        <DetailsToggle chevronPosition="none">Limit sales</DetailsToggle>
      </Details>,
    );

    expect(document.querySelector("summary svg")).toBeNull();
  });
});
