// @vitest-environment happy-dom
//
// Covers the two pieces that make opening a product feel instant instead of dead
// (gumroad-private#1469):
//
//   * the Products list fetches the product editor's code up front, so the click has nothing left
//     to download, and
//   * if it does still have to wait, the editor's place is held by a skeleton that already names
//     the product, rather than by the previous page.
//
// The editor itself is a large separate chunk, so both are load-order behaviour rather than
// rendering behaviour, and neither is visible in a spec that only asserts the finished page.
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ProductEditLoadingSkeleton } from "$app/components/ProductEdit/LoadingSkeleton";

// Count fetches of the editor's chunk without loading the real thing.
const editorChunkLoads = vi.fn();
vi.mock("$app/components/server-components/ProductEditPage", () => {
  editorChunkLoads();
  return { ProductEditPage: () => <div>editor</div> };
});

afterEach(() => {
  cleanup();
  editorChunkLoads.mockClear();
});

describe("product editor loading", () => {
  it("fetches the editor's code from the Products list, before anything is clicked", async () => {
    const { useWarmProductEditPage } = await import("$app/components/ProductEdit/load");
    const ProductsList = () => {
      useWarmProductEditPage();
      return <div>products</div>;
    };

    render(<ProductsList />);

    await waitFor(() => expect(editorChunkLoads).toHaveBeenCalled());
  });

  it("holds the editor's place with a skeleton that names the product being opened", () => {
    render(<ProductEditLoadingSkeleton title="Course in a Box" />);

    // The name is already in the props the server sent, so showing it confirms the click landed on
    // the right product — which is the whole complaint behind this change.
    expect(screen.getByRole("heading", { name: "Course in a Box" })).toBeTruthy();
    expect(screen.getByText("Loading product…")).toBeTruthy();
    // Screen readers get told the region is still filling in, not that it is empty.
    expect(document.querySelector("[aria-busy='true']")).toBeTruthy();
  });

  it("still renders a placeholder heading when the product has no name yet", () => {
    render(<ProductEditLoadingSkeleton title={null} />);

    expect(screen.getByText("Loading product…")).toBeTruthy();
    expect(screen.queryByRole("heading")).toBeNull();
  });
});
