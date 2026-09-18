// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { PageTab, type Page } from "$app/components/ProductEdit/ContentTab/PageTab";

// Keep the unrelated popover hooks out of this handle-contract test.
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

describe("PageTab move handle", () => {
  it("matches the Sortable handle selector", () => {
    expect(renderHandle().matches("[aria-grabbed]")).toBe(true);
  });
});
