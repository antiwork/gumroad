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
  it("renders folders collapsed by default", () => {
    render(<FileList content_items={[folder()]} />);

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("false");
  });

  it("renders folders expanded when the seller enabled expand_folders", () => {
    render(<FileList content_items={[folder()]} expand_folders />);

    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("true");
  });

  it("still allows collapsing a folder that started expanded", () => {
    render(<FileList content_items={[folder()]} expand_folders />);

    fireEvent.click(screen.getByRole("heading", { name: "GOYOW" }));
    expect(screen.getByRole("treeitem", { name: /GOYOW/u }).getAttribute("aria-expanded")).toBe("false");
  });
});
