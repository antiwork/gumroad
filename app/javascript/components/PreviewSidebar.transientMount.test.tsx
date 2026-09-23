// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { UserAgentProvider } from "$app/components/UserAgent";

// Real hooks on purpose. The defect lives in the FIRST commit — before `useWindowDimensions` has
// measured, because it measures in a passive effect — so a test that mocks the breakpoint hook
// only ever sees the settled state and passes against the unfixed component too. `overrideNull`
// pins that unmeasured commit for the second case; otherwise the real measurement runs.
const overrideNull = { current: false };
vi.mock("$app/components/useWindowDimensions", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/components/useWindowDimensions")>();
  return {
    useWindowDimensions: (...args: Parameters<typeof actual.useWindowDimensions>) =>
      overrideNull.current ? null : actual.useWindowDimensions(...args),
  };
});

// Counts mounts, not renders: the defect is a second mount of the preview. The hidden aside copy
// is dropped once the viewport turns out to be below lg, and the mobile pane then mounts its own.
const mountCount = { current: 0 };
const Preview = () => {
  React.useEffect(() => {
    mountCount.current += 1;
  }, []);
  return <div title="Page preview">the live page</div>;
};

// Desktop user agent (isMobile: false) — the affected population is a desktop browser window
// narrower than lg (split screen, small laptop window), not a phone.
const renderSidebar = () =>
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en" }}>
      <WithPreviewSidebar>
        <div>the edit form</div>
        <PreviewSidebar>
          <Preview />
        </PreviewSidebar>
      </WithPreviewSidebar>
    </UserAgentProvider>,
  );

describe("PreviewSidebar first-commit mount", () => {
  afterEach(() => {
    cleanup();
    overrideNull.current = false;
    mountCount.current = 0;
  });

  it("mounts the preview once for a desktop window below lg, in Preview mode", () => {
    // happy-dom has no `--breakpoint-lg`, so the real hook settles below lg: a desktop window too
    // narrow for the sidebar. Before the gate this mounted twice — once inside the display:none
    // aside on the first commit, once in the pane after the measurement.
    renderSidebar();
    fireEvent.click(screen.getByRole("tab", { name: "Preview" }));

    expect(mountCount.current).toBe(1);
    expect(screen.getAllByTitle("Page preview")).toHaveLength(1);
  });

  it("holds no children in the aside while the viewport is unmeasured", () => {
    overrideNull.current = true;
    renderSidebar();

    expect(screen.getByLabelText("Preview").children).toHaveLength(0);
    expect(mountCount.current).toBe(0);
  });
});
