// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PageTab, type Page } from "$app/components/ProductEdit/ContentTab/PageTab";

// Radix's popover pulls in its own React copy under vitest's resolution and dies on
// `useMemo`. It is the row's rename/delete menu, unrelated to the drag handle under test.
vi.mock("$app/components/Popover", () => {
  const Passthrough = ({ children }: { children?: React.ReactNode }) => <div>{children}</div>;
  return { Popover: Passthrough, PopoverContent: Passthrough, PopoverTrigger: Passthrough };
});

afterEach(cleanup);

const page: Page = {
  id: "page-1",
  title: "Sunday Edition",
  description: {},
  updated_at: "2026-09-17T00:00:00Z",
};

const renderHandle = () => {
  const { container } = render(
    <PageTab
      page={page}
      selected={false}
      dragging={false}
      renaming={false}
      setRenaming={() => {}}
      icon="text-only"
      onClick={() => {}}
      onUpdate={() => {}}
      onDelete={() => {}}
    />,
  );

  const handle = container.querySelector("[aria-grabbed]");
  if (!handle) throw new Error("PageTab rendered no drag handle");
  return handle;
};

describe("PageTab move handle on touch devices", () => {
  // The ContentTab Sortable is bound with `handle="[aria-grabbed]"`, so this element is the
  // only place a drag can begin. It used to be `visibility: hidden` until hover, and a hidden
  // element cannot be a touch target at all, so the drag never started on a phone.
  // See https://github.com/antiwork/gumroad-private/issues/2760
  it("marks the handle with the attribute the Sortable's handle selector matches", () => {
    expect(renderHandle().matches("[aria-grabbed]")).toBe(true);
  });

  // `pointer-coarse:visible` is Tailwind's `@media (pointer: coarse)` variant — the same
  // device signal the dashboard already uses for affordances that cannot rely on hover.
  it("shows the handle without hover on a coarse pointer", () => {
    expect(renderHandle().classList.contains("pointer-coarse:visible")).toBe(true);
  });

  // Desktop stays hover-only: a mouse pointer can still hover the row, and showing the handle
  // permanently there would change the row's resting appearance.
  it("keeps the handle hover-only on fine pointers", () => {
    const handle = renderHandle();

    expect(handle.classList.contains("invisible")).toBe(true);
    expect(handle.classList.contains("group-hover/tab:visible")).toBe(true);
  });
});
