// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { type OmnibarSearchResults } from "$app/data/omnibar";

import { OmnibarDialog, OmnibarTrigger, useOmnibar } from "$app/components/Omnibar";

const visit = vi.fn();
vi.mock("@inertiajs/react", () => ({ router: { visit: (href: string) => visit(href) } }));

const searchOmnibar = vi.fn<(query: string, signal: AbortSignal) => Promise<OmnibarSearchResults>>();
vi.mock("$app/data/omnibar", () => ({
  searchOmnibar: (query: string, signal: AbortSignal) => searchOmnibar(query, signal),
}));

beforeAll(() => {
  const withQuery = (path: string) => (params: { query: string }) =>
    `${path}?query=${encodeURIComponent(params.query)}`;
  Object.assign(globalThis, {
    Routes: { customers_path: withQuery("/customers"), products_path: withQuery("/products") },
  });
});

beforeEach(() => {
  vi.useFakeTimers();
  searchOmnibar.mockReset();
  visit.mockReset();
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  document.body.className = "";
});

const pages = [
  { key: "products", title: "Products", href: "/products" },
  { key: "sales", title: "Sales", href: "/customers", keywords: "customers refunds" },
  { key: "payouts", title: "Payouts", href: "/payouts" },
];
const actions = [{ key: "new-product", title: "New product", href: "/products/new", keywords: "create" }];
const results: OmnibarSearchResults = {
  products: [{ id: "p1", name: "Beautiful widget", url: "/products/p1/edit" }],
  customers: [
    {
      id: "c1",
      email: "ada@example.com",
      name: "Ada Lovelace",
      product_name: "Beautiful widget",
      url: "/customers/sale/c1",
    },
  ],
  customers_unavailable: false,
};

const Harness = () => {
  const omnibar = useOmnibar();
  return (
    <>
      <OmnibarTrigger variant="sidebar" onOpen={omnibar.show} />
      <OmnibarDialog open={omnibar.open} onClose={omnibar.hide} pages={pages} actions={actions} />
    </>
  );
};

const openBar = () => {
  render(<Harness />);
  fireEvent.click(screen.getByRole("button", { name: "Search" }));
  return screen.getByRole("combobox", { name: "Search products, sales and pages" });
};
const type = (input: HTMLElement, value: string) => fireEvent.change(input, { target: { value } });
const optionNames = () => screen.getAllByRole("option").map((option) => option.textContent);
const activeOption = (input: HTMLElement) => {
  const id = input.getAttribute("aria-activedescendant");
  return id ? document.getElementById(id) : null;
};
// The search waits out its delay, then its promise settles.
const settleSearch = () => act(() => vi.advanceTimersByTimeAsync(300));

describe("Omnibar", () => {
  it("opens from the field with the cursor in it and every place and action listed", () => {
    const input = openBar();

    expect(document.activeElement).toBe(input);
    expect(optionNames()).toEqual(["Products", "Sales", "Payouts", "New product"]);
    expect(within(screen.getByRole("group", { name: "Go to" })).getAllByRole("option")).toHaveLength(3);
    expect(activeOption(input)?.textContent).toBe("Products");
  });

  it("narrows the places as the seller types, on other words for a place too", () => {
    const input = openBar();

    type(input, "refund");

    expect(optionNames()).toEqual(["Sales", "Search sales for “refund”", "Search products for “refund”"]);
  });

  it("moves through the rows with the arrow keys and wraps", () => {
    const input = openBar();

    fireEvent.keyDown(input, { key: "ArrowDown" });
    expect(activeOption(input)?.textContent).toBe("Sales");
    expect(activeOption(input)?.getAttribute("aria-selected")).toBe("true");

    fireEvent.keyDown(input, { key: "ArrowUp" });
    fireEvent.keyDown(input, { key: "ArrowUp" });
    expect(activeOption(input)?.textContent).toBe("New product");
  });

  it("opens the active row on Enter and closes", () => {
    const input = openBar();

    fireEvent.keyDown(input, { key: "ArrowDown" });
    fireEvent.keyDown(input, { key: "Enter" });

    expect(visit).toHaveBeenCalledWith("/customers");
    expect(screen.queryByRole("combobox")).toBeNull();
  });

  it("leaves Enter to an input method that is still composing", () => {
    const input = openBar();

    fireEvent.keyDown(input, { key: "Enter", isComposing: true });

    expect(visit).not.toHaveBeenCalled();
  });

  it("opens a clicked row", () => {
    openBar();

    fireEvent.click(screen.getByRole("option", { name: "Payouts" }));

    expect(visit).toHaveBeenCalledWith("/payouts");
    expect(screen.queryByRole("combobox")).toBeNull();
  });

  it("leaves a ⌘-click to the browser so the row opens in a new tab", () => {
    openBar();

    fireEvent.click(screen.getByRole("option", { name: "Payouts" }), { metaKey: true });

    expect(visit).not.toHaveBeenCalled();
    expect(screen.getByRole("combobox")).toBeTruthy();
  });

  it("searches the server from two characters, after a pause", async () => {
    searchOmnibar.mockResolvedValue(results);
    const input = openBar();

    type(input, "a");
    await settleSearch();
    expect(searchOmnibar).not.toHaveBeenCalled();

    type(input, "ad");
    type(input, "ada");
    await settleSearch();

    expect(searchOmnibar).toHaveBeenCalledTimes(1);
    expect(searchOmnibar.mock.calls[0]?.[0]).toBe("ada");
    expect(within(screen.getByRole("group", { name: "Products" })).getByRole("option").textContent).toBe(
      "Beautiful widget",
    );
    expect(within(screen.getByRole("group", { name: "Sales" })).getByRole("option").textContent).toBe(
      "Ada Lovelaceada@example.com · Beautiful widget",
    );
  });

  it("does not show an answer to an earlier query", async () => {
    let answerFirst: (value: OmnibarSearchResults) => void = () => undefined;
    searchOmnibar.mockImplementationOnce(() => new Promise((resolve) => (answerFirst = resolve)));
    searchOmnibar.mockResolvedValueOnce({ products: [], customers: [], customers_unavailable: false });
    const input = openBar();

    type(input, "wid");
    await settleSearch();
    type(input, "widgets");
    await settleSearch();
    await act(() => {
      answerFirst(results);
      return Promise.resolve();
    });

    expect(screen.queryByRole("option", { name: "Beautiful widget" })).toBeNull();
    expect(screen.getByText("No products or sales match “widgets”.")).toBeTruthy();
  });

  it("says so when the search fails, and still jumps to places", async () => {
    searchOmnibar.mockRejectedValue(new Error("offline"));
    const input = openBar();

    type(input, "pay");
    await settleSearch();

    expect(screen.getByText("Couldn't search your products and sales. You can still jump to a page.")).toBeTruthy();
    fireEvent.keyDown(input, { key: "Enter" });
    expect(visit).toHaveBeenCalledWith("/payouts");
  });

  it("says so when only sales could not be searched", async () => {
    searchOmnibar.mockResolvedValue({ ...results, customers: [], customers_unavailable: true });
    const input = openBar();

    type(input, "wid");
    await settleSearch();

    expect(screen.getByRole("option", { name: "Beautiful widget" })).toBeTruthy();
    expect(screen.getByText("Sales can't be searched right now. Products and pages still can.")).toBeTruthy();
  });

  // "Copy" on an email link in a mail client puts the whole mailto: link on the clipboard.
  it("drops a pasted mailto: prefix", async () => {
    searchOmnibar.mockResolvedValue(results);
    const input = openBar();

    type(input, "mailto:ada@example.com");
    await settleSearch();

    expect(input).toHaveProperty("value", "ada@example.com");
    expect(searchOmnibar.mock.calls[0]?.[0]).toBe("ada@example.com");
  });

  it("starts empty each time it opens", () => {
    const input = openBar();
    type(input, "pay");
    fireEvent.click(screen.getByRole("button", { name: "Close" }));

    fireEvent.click(screen.getByRole("button", { name: "Search" }));

    expect(screen.getByRole("combobox")).toHaveProperty("value", "");
  });

  describe("keyboard shortcut", () => {
    const press = (init: KeyboardEventInit) => fireEvent.keyDown(document.body, { key: "k", ...init });

    it("opens on Ctrl+K", () => {
      render(<Harness />);

      press({ ctrlKey: true });

      expect(screen.getByRole("combobox")).toBeTruthy();
    });

    it("opens on ⌘K on a Mac", () => {
      document.body.className = "mac";
      render(<Harness />);

      press({ metaKey: true });

      expect(screen.getByRole("combobox")).toBeTruthy();
    });

    // Ctrl+K deletes to the end of the line in every macOS text field.
    it("leaves Ctrl+K alone on a Mac", () => {
      document.body.className = "mac";
      render(<Harness />);

      press({ ctrlKey: true });

      expect(screen.queryByRole("combobox")).toBeNull();
    });

    it("names the shortcut for the platform on the field", () => {
      document.body.className = "mac";
      render(<Harness />);

      expect(screen.getByRole("button", { name: "Search" }).getAttribute("aria-keyshortcuts")).toBe("Meta+K");
      expect(screen.getByText("⌘K")).toBeTruthy();
    });
  });
});
