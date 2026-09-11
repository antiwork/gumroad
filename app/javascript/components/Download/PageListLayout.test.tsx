// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { PageListLayout } from "$app/components/Download/PageListLayout";

afterEach(cleanup);

describe("PageListLayout", () => {
  it("keeps the content pane from collapsing to height 0 next to the sidebar", () => {
    render(
      <PageListLayout pageList={<div>Liked it? Give it a rating:</div>}>
        <a href="/download">Download</a>
      </PageListLayout>,
    );

    expect(screen.getByRole("link", { name: "Download" })).toBeTruthy();
    const contentPane = screen.getByRole("link", { name: "Download" }).parentElement;
    expect(contentPane?.classList.contains("min-h-0")).toBe(true);
    expect(contentPane?.classList.contains("min-w-0")).toBe(true);
    expect(contentPane?.classList.contains("flex-1")).toBe(true);
    expect(contentPane?.classList.contains("h-0")).toBe(false);
  });
});
