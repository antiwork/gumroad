// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { type OmnibarProduct, type OmnibarSale } from "$app/data/omnibar";

import { OmnibarDialog, OmnibarTrigger, useOmnibar } from "$app/components/Omnibar";

const visit = vi.fn();
vi.mock("@inertiajs/react", () => ({ router: { visit: (href: string) => visit(href) } }));

const searchProducts = vi.fn<(query: string, signal: AbortSignal) => Promise<OmnibarProduct[]>>();
const searchSales = vi.fn<(query: string, signal: AbortSignal) => Promise<OmnibarSale[]>>();
vi.mock("$app/data/omnibar", () => ({
  searchOmnibarProducts: (query: string, signal: AbortSignal) => searchProducts(query, signal),
  searchOmnibarSales: (query: string, signal: AbortSignal) => searchSales(query, signal),
}));

beforeAll(() => {
  const withQuery = (path: string) => (params: { query: string }) =>
    `${path}?query=${encodeURIComponent(params.query)}`;
  Object.assign(globalThis, {
    Routes: { customers_path: withQuery("/customers"), products_path: withQuery("/products") },
  });
});

const widget: OmnibarProduct = { id: "p1", name: "Beautiful widget", url: "/products/p1/edit" };
const ada: OmnibarSale = {
  id: "s1",
  email: "ada@example.com",
  name: "Ada Lovelace",
  product_name: "Beautiful widget",
  url: "/customers/sale/s1",
};

const rememberReferrer = vi.fn();

beforeEach(() => {
  vi.useFakeTimers();
  visit.mockReset();
  rememberReferrer.mockReset();
  searchProducts.mockReset().mockResolvedValue([widget]);
  searchSales.mockReset().mockResolvedValue([ada]);
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.restoreAllMocks();
  document.body.className = "";
});

const pages = [
  { key: "products", title: "Products", href: "/products" },
  { key: "sales", title: "Sales", href: "/customers", keywords: "customers refunds" },
  { key: "payouts", title: "Payouts", href: "/payouts" },
  { key: "community", title: "Community", href: "/communities", onSelect: rememberReferrer },
  { key: "discover", title: "Discover", href: "https://discover.example.com/" },
];
const actions = [{ key: "new-product", title: "New product", href: "/products/new", keywords: "create" }];

const Harness = () => {
  const omnibar = useOmnibar();
  return (
    <>
      <OmnibarTrigger variant="sidebar" onOpen={omnibar.show} />
      <OmnibarDialog open={omnibar.open} onClose={omnibar.hide} pages={pages} actions={actions} />
    </>
  );
};

const trigger = () => screen.getByRole("button", { name: "Search" });
const openBar = () => {
  render(<Harness />);
  trigger().focus();
  fireEvent.click(trigger());
  return screen.getByRole("combobox", { name: "Search products, sales and pages" });
};
const type = (input: HTMLElement, value: string) => fireEvent.change(input, { target: { value } });
const optionNames = () => screen.queryAllByRole("option").map((option) => option.textContent);
const activeOption = (input: HTMLElement) => {
  const id = input.getAttribute("aria-activedescendant");
  return id ? document.getElementById(id) : null;
};
// The search waits out its delay, then its promises settle.
const settleSearch = () => act(() => vi.advanceTimersByTimeAsync(300));
const deferred = <T,>() => {
  let settle: (value: T) => void = () => undefined;
  const promise = new Promise<T>((resolve) => {
    settle = resolve;
  });
  return {
    promise,
    resolve: (value: T) =>
      act(async () => {
        settle(value);
        await Promise.resolve();
      }),
  };
};

describe("Omnibar", () => {
  it("opens from the field with the cursor in it and every place and action listed", () => {
    const input = openBar();

    expect(document.activeElement).toBe(input);
    expect(optionNames()).toEqual(["Products", "Sales", "Payouts", "Community", "Discover", "New product"]);
    expect(within(screen.getByRole("group", { name: "Go to" })).getAllByRole("option")).toHaveLength(5);
    expect(activeOption(input)?.textContent).toBe("Products");
    expect(screen.getByRole("status").textContent).toBe("6 results");
  });

  it("narrows the places as the seller types, on other words for a place too", () => {
    const input = openBar();

    type(input, "refund");

    expect(optionNames()).toEqual(["Sales"]);
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

  // Safari ends the composition before the Enter that commits it, and reports only the key code.
  it.each([{ isComposing: true }, { keyCode: 229 }])("leaves Enter to an input method (%o)", (init) => {
    const input = openBar();

    fireEvent.keyDown(input, { key: "Enter", ...init });

    expect(visit).not.toHaveBeenCalled();
    expect(screen.getByRole("combobox")).toBeTruthy();
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

  it("opens the active row in a new tab on ⌘+Enter and stays open", () => {
    const open = vi.spyOn(window, "open").mockReturnValue(null);
    const input = openBar();

    fireEvent.keyDown(input, { key: "Enter", metaKey: true });

    expect(open).toHaveBeenCalledWith("/products", "_blank", "noopener");
    expect(visit).not.toHaveBeenCalled();
    expect(screen.getByRole("combobox")).toBeTruthy();
  });

  it("leaves the app's router out of a destination on another host", () => {
    const assign = vi.spyOn(window.location, "assign").mockImplementation(() => undefined);
    openBar();

    fireEvent.click(screen.getByRole("option", { name: "Discover" }));

    expect(assign).toHaveBeenCalledWith("https://discover.example.com/");
    expect(visit).not.toHaveBeenCalled();
  });

  // The Community row stores where the seller came from, for its "Go back".
  it("runs a place's own handler before visiting it", () => {
    openBar();

    fireEvent.click(screen.getByRole("option", { name: "Community" }));

    expect(rememberReferrer).toHaveBeenCalledTimes(1);
    expect(visit).toHaveBeenCalledWith("/communities");
  });

  it("puts focus back on the field that opened it", async () => {
    const input = openBar();

    fireEvent.keyDown(input, { key: "Escape" });
    await act(() => vi.advanceTimersByTimeAsync(0));

    expect(screen.queryByRole("combobox")).toBeNull();
    expect(document.activeElement).toBe(trigger());
  });

  it("starts empty each time it opens", () => {
    const input = openBar();
    type(input, "pay");
    fireEvent.click(screen.getByRole("button", { name: "Close" }));

    fireEvent.click(trigger());

    expect(screen.getByRole("combobox")).toHaveProperty("value", "");
    expect(optionNames()).toHaveLength(6);
  });

  describe("searching the server", () => {
    it("asks for products and sales from two characters, after a pause", async () => {
      const input = openBar();

      type(input, "a");
      await settleSearch();
      expect(searchProducts).not.toHaveBeenCalled();

      type(input, "ad");
      type(input, "ada");
      expect(screen.getByRole("status").textContent).toBe("Searching");
      await settleSearch();

      expect(searchProducts.mock.calls.map(([query]) => query)).toEqual(["ada"]);
      expect(searchSales.mock.calls.map(([query]) => query)).toEqual(["ada"]);
      expect(within(screen.getByRole("group", { name: "Products" })).getByRole("option").textContent).toBe(
        "Beautiful widget",
      );
      expect(within(screen.getByRole("group", { name: "Sales" })).getByRole("option").textContent).toBe(
        "Ada Lovelaceada@example.com · Beautiful widget",
      );
      expect(optionNames().slice(-2)).toEqual(["Search sales for “ada”", "Search products for “ada”"]);
      expect(screen.getByRole("status").textContent).toBe("4 results");
    });

    it("shows products without waiting for sales", async () => {
      const sales = deferred<OmnibarSale[]>();
      searchSales.mockReturnValue(sales.promise);
      const input = openBar();

      type(input, "wid");
      await settleSearch();
      expect(optionNames()).toEqual(["Beautiful widget"]);

      await sales.resolve([ada]);
      expect(optionNames()).toEqual([
        "Beautiful widget",
        "Ada Lovelaceada@example.com · Beautiful widget",
        "Search sales for “wid”",
        "Search products for “wid”",
      ]);
    });

    it("does not show an answer to an earlier query", async () => {
      const first = deferred<OmnibarProduct[]>();
      searchProducts.mockReturnValueOnce(first.promise).mockResolvedValueOnce([]);
      searchSales.mockResolvedValue([]);
      const input = openBar();

      type(input, "wid");
      await settleSearch();
      type(input, "widgets");
      await settleSearch();
      await first.resolve([widget]);

      expect(screen.queryByRole("option", { name: "Beautiful widget" })).toBeNull();
      expect(screen.getByRole("status").textContent).toBe("No products or sales match “widgets”.");
    });

    it("cancels the request when the bar closes", async () => {
      const input = openBar();
      type(input, "wid");
      await settleSearch();

      fireEvent.click(screen.getByRole("button", { name: "Close" }));

      expect(searchProducts.mock.calls[0]?.[1].aborted).toBe(true);
      expect(searchSales.mock.calls[0]?.[1].aborted).toBe(true);
    });

    it("says so when the search fails, and still jumps to places", async () => {
      searchProducts.mockRejectedValue(new Error("offline"));
      searchSales.mockRejectedValue(new Error("offline"));
      const input = openBar();

      type(input, "pay");
      await settleSearch();

      expect(screen.getByRole("status").textContent).toBe(
        "Couldn't search your products and sales. You can still jump to a page.",
      );
      fireEvent.keyDown(input, { key: "Enter" });
      expect(visit).toHaveBeenCalledWith("/payouts");
    });

    it("says so when only sales could not be searched", async () => {
      searchSales.mockRejectedValue(new Error("index down"));
      const input = openBar();

      type(input, "wid");
      await settleSearch();

      expect(screen.getByRole("option", { name: "Beautiful widget" })).toBeTruthy();
      expect(screen.getByRole("status").textContent).toBe(
        "Sales can't be searched right now. Products and pages still can.",
      );
    });

    it("asks for more when one character matches no place", () => {
      const input = openBar();

      type(input, "z");

      expect(screen.getByRole("status").textContent).toBe("Keep typing to search your products and sales.");
      expect(input.getAttribute("aria-expanded")).toBe("false");
    });

    // "Copy" on an email link in a mail client puts the whole mailto: link on the clipboard.
    it("drops a pasted mailto: prefix", async () => {
      const input = openBar();

      type(input, "mailto:ada@example.com");
      await settleSearch();

      expect(input).toHaveProperty("value", "ada@example.com");
      expect(searchSales.mock.calls[0]?.[0]).toBe("ada@example.com");
    });

    describe("Enter before any row has arrived", () => {
      it("opens the first row when it arrives", async () => {
        const input = openBar();

        type(input, "wid");
        fireEvent.keyDown(input, { key: "Enter" });
        expect(visit).not.toHaveBeenCalled();
        await settleSearch();

        expect(visit).toHaveBeenCalledWith("/products/p1/edit");
        expect(screen.queryByRole("combobox")).toBeNull();
      });

      it("opens the Sales page's search when nothing matched", async () => {
        searchProducts.mockResolvedValue([]);
        searchSales.mockResolvedValue([]);
        const input = openBar();

        type(input, "nobody@example.com");
        fireEvent.keyDown(input, { key: "Enter" });
        await settleSearch();

        expect(visit).toHaveBeenCalledWith("/customers?query=nobody%40example.com");
      });

      it("is forgotten when the seller keeps typing", async () => {
        const input = openBar();

        type(input, "wid");
        fireEvent.keyDown(input, { key: "Enter" });
        type(input, "widg");
        await settleSearch();

        expect(visit).not.toHaveBeenCalled();
        expect(screen.getByRole("combobox")).toBeTruthy();
      });
    });
  });

  describe("keyboard shortcut", () => {
    const press = (init: KeyboardEventInit) => fireEvent.keyDown(document.body, { key: "k", code: "KeyK", ...init });

    it("opens on Ctrl+K and keeps the key from the browser", () => {
      render(<Harness />);

      // fireEvent returns false when the handler prevented the default action.
      expect(press({ ctrlKey: true })).toBe(false);
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

      expect(press({ ctrlKey: true })).toBe(true);
      expect(screen.queryByRole("combobox")).toBeNull();
    });

    it.each([{ ctrlKey: true, shiftKey: true }, { ctrlKey: true, altKey: true }, { metaKey: true }, {}])(
      "ignores %o off a Mac",
      (init) => {
        render(<Harness />);

        expect(press(init)).toBe(true);
        expect(screen.queryByRole("combobox")).toBeNull();
      },
    );

    // Ctrl does not switch a Cyrillic layout to Latin, so the K key reports "л".
    it("opens on the K key of a non-Latin layout", () => {
      render(<Harness />);

      press({ key: "л", ctrlKey: true });

      expect(screen.getByRole("combobox")).toBeTruthy();
    });

    it("follows the printed K, not its position, on another Latin layout", () => {
      render(<Harness />);

      press({ key: "t", ctrlKey: true });

      expect(screen.queryByRole("combobox")).toBeNull();
    });

    // Browser autofill dispatches a keydown that is not a KeyboardEvent and has no key.
    it("ignores a keydown with no key", () => {
      render(<Harness />);

      expect(() => document.dispatchEvent(new Event("keydown", { bubbles: true }))).not.toThrow();
      expect(screen.queryByRole("combobox")).toBeNull();
    });

    it("names the shortcut for the platform on the field", () => {
      document.body.className = "mac";
      render(<Harness />);

      expect(trigger().getAttribute("aria-keyshortcuts")).toBe("Meta+K");
      expect(screen.getByText("⌘K")).toBeTruthy();
    });
  });
});
