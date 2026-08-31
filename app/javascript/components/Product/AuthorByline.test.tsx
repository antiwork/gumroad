// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { AuthorByline } from "$app/components/Product/AuthorByline";

afterEach(() => {
  cleanup();
});

describe("AuthorByline", () => {
  it("truncates the name inside a min-w-0 flex row instead of wrapping mid-word", () => {
    render(
      <AuthorByline
        name="Measure Twice Digital"
        profileUrl="https://measuretwicedigital.gumroad.com"
        avatarUrl="https://example.com/avatar.png"
      />,
    );

    const link = screen.getByRole("link", { name: "Measure Twice Digital" });
    expect(link.className.split(" ")).toContain("min-w-0");
    const name = link.querySelector("span");
    expect(name?.textContent).toBe("Measure Twice Digital");
    expect(name?.className.split(" ")).toContain("truncate");
    expect(name?.className.split(" ")).toContain("min-w-0");
  });
});
