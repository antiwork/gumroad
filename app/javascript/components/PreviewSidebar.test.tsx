// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";

// The real hook reads the `lg` breakpoint CSS variable out of the document, which a happy-dom
// test has no stylesheet for (it resolves to NaN, i.e. "below lg"). Drive it directly instead so
// both sides of the breakpoint are covered.
const isAboveBreakpoint = { current: true };
vi.mock("$app/components/useIsAboveBreakpoint", () => ({
  useIsAboveBreakpoint: () => isAboveBreakpoint.current,
}));

// The real previews are iframes of live pages; the sidebar only passes `children` through, so a
// plain element keeps the test off the network.
const preview = () => <div title="Page preview">the live page</div>;

describe("PreviewSidebar", () => {
  afterEach(() => {
    cleanup();
    isAboveBreakpoint.current = true;
  });

  it("renders the preview in the aside above lg", () => {
    isAboveBreakpoint.current = true;
    render(
      <WithPreviewSidebar>
        <div>the edit form</div>
        <PreviewSidebar>{preview()}</PreviewSidebar>
      </WithPreviewSidebar>,
    );

    expect(screen.getAllByTitle("Page preview")).toHaveLength(1);
    expect(screen.queryByRole("tab", { name: "Preview" })).toBeNull();
  });

  it("does not mount the preview below lg while the seller is editing", () => {
    isAboveBreakpoint.current = false;
    render(
      <WithPreviewSidebar>
        <div>the edit form</div>
        <PreviewSidebar>{preview()}</PreviewSidebar>
      </WithPreviewSidebar>,
    );

    // The mobile shell is there (its Edit/Preview toggle), but the preview is not mounted: the
    // aside holding it is display:none at this width, and previews are live pages, not thumbnails.
    expect(screen.getByRole("tab", { name: "Preview" })).not.toBeNull();
    expect(screen.queryByTitle("Page preview")).toBeNull();
  });

  it("mounts the preview exactly once below lg in Preview mode", () => {
    isAboveBreakpoint.current = false;
    render(
      <WithPreviewSidebar>
        <div>the edit form</div>
        <PreviewSidebar>{preview()}</PreviewSidebar>
      </WithPreviewSidebar>,
    );

    fireEvent.click(screen.getByRole("tab", { name: "Preview" }));

    expect(screen.getAllByTitle("Page preview")).toHaveLength(1);
  });

  it("keeps rendering the preview in the aside when there is no mobile pane to take over", () => {
    // Previews that don't opt into the mobile Edit/Preview shell (e.g. the checkout preview) have
    // no pane below lg, so the aside stays the only place the preview can live.
    isAboveBreakpoint.current = false;
    render(<PreviewSidebar>{preview()}</PreviewSidebar>);

    expect(screen.getAllByTitle("Page preview")).toHaveLength(1);
  });
});
