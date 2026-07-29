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
// rendering behaviour, and neither is visible in a spec that only asserts the finished page. That
// chunk arrives over the network, so the tests below also cover what happens when it does not
// arrive: one retry, then a visible way out rather than a blank page.
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { ProductEditBoundary } from "$app/components/ProductEdit/Boundary";
import { ProductEditLoadingSkeleton } from "$app/components/ProductEdit/LoadingSkeleton";

// Rails routes reach the app as a `Routes` global that vitest does not have. Only the products
// path is needed here, and asserting against the real value is the point of one of the tests below.
vi.stubGlobal("Routes", { products_path: () => "/products" });

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

  it("retries once when the editor's code fails to download, so a blip doesn't cost the seller the page", async () => {
    const { fetchWithOneRetry } = await import("$app/components/ProductEdit/load");
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new Error("Failed to fetch dynamically imported module"))
      .mockResolvedValueOnce("editor chunk");

    // Pass 0 so the test does not sit through the real pause.
    await expect(fetchWithOneRetry(fetch, 0)).resolves.toBe("editor chunk");
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("gives up after the retry rather than fetching forever, and reports the original failure", async () => {
    const { fetchWithOneRetry } = await import("$app/components/ProductEdit/load");
    const fetch = vi
      .fn()
      .mockRejectedValueOnce(new Error("Failed to fetch dynamically imported module"))
      .mockRejectedValueOnce(new Error("retry also failed"));

    await expect(fetchWithOneRetry(fetch, 0)).rejects.toThrow("Failed to fetch dynamically imported module");
    expect(fetch).toHaveBeenCalledTimes(2);
  });

  it("does not retry when the first fetch succeeds", async () => {
    const { fetchWithOneRetry } = await import("$app/components/ProductEdit/load");
    const fetch = vi.fn().mockResolvedValue("editor chunk");

    await expect(fetchWithOneRetry(fetch, 0)).resolves.toBe("editor chunk");
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("offers a way out instead of a blank page when the editor cannot be loaded at all", () => {
    // React logs the caught error; the boundary handling it is the point, so keep the output quiet.
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    const Exploding = () => {
      throw new Error("Failed to fetch dynamically imported module");
    };

    render(
      <ProductEditBoundary>
        <Exploding />
      </ProductEditBoundary>,
    );

    // Before this boundary existed, a failed chunk load unmounted the whole tree and the seller saw
    // nothing at all — indistinguishable from the dead-click complaint behind this change.
    expect(screen.getByRole("alert")).toBeTruthy();
    expect(
      screen.getByRole("heading", { name: /couldn’t open this product|couldn't open this product/u }),
    ).toBeTruthy();
    expect(screen.getByRole("button", { name: "Try again" })).toBeTruthy();
    // A link, not a history action: someone who opened the editor in a new tab or from a bookmark
    // has no history to go back to, so "Back to products" has to name where it goes.
    expect(screen.getByRole("link", { name: "Back to products" }).getAttribute("href")).toBe("/products");

    consoleError.mockRestore();
  });

  it("renders its children untouched while nothing is failing", () => {
    render(
      <ProductEditBoundary>
        <div>editor</div>
      </ProductEditBoundary>,
    );

    expect(screen.getByText("editor")).toBeTruthy();
    expect(screen.queryByRole("alert")).toBeNull();
  });
});
