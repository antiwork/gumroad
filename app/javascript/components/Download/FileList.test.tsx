// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { FileList, FolderItem } from "$app/components/Download/FileList";

afterEach(cleanup);

const folder = (overrides: Partial<FolderItem> = {}): FolderItem => ({
  type: "folder",
  id: "folder-1",
  name: "GOYOW",
  children: [],
  ...overrides,
});

describe("FileList", () => {
  it("renders folders collapsed by default when the page has multiple folders", () => {
    render(<FileList content_items={[folder(), folder({ id: "folder-2", name: "Extras" })]} />);

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("false");
    expect(screen.getByRole("treeitem", { name: /Extras/u }).getAttribute("aria-expanded")).toBe("false");
  });

  it("renders a folder expanded when the seller enabled expanded_by_default on it", () => {
    render(
      <FileList content_items={[folder({ expanded_by_default: true }), folder({ id: "folder-2", name: "Extras" })]} />,
    );

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("true");
    expect(screen.getByRole("treeitem", { name: /Extras/u }).getAttribute("aria-expanded")).toBe("false");
  });

  it("renders a single top-level folder expanded even without the per-folder setting", () => {
    render(<FileList content_items={[folder()]} />);

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("true");
  });

  it("still allows collapsing a folder that started expanded", () => {
    render(<FileList content_items={[folder({ expanded_by_default: true })]} />);

    fireEvent.click(screen.getByRole("heading", { name: "GOYOW" }));
    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("false");
  });
});
