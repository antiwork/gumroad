// @vitest-environment happy-dom
import { cleanup, renderHook } from "@testing-library/react";
import * as React from "react";
import { act } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { useEmailSearch } from "$app/components/EmailsPage/useEmailSearch";
import { useProductsSearch } from "$app/components/ProductsPage/useProductsSearch";

const reload = vi.hoisted(() => vi.fn());
vi.mock("@inertiajs/react", () => ({ router: { reload } }));

beforeEach(() => {
  vi.useFakeTimers();
  window.history.replaceState({}, "", "/");
});
afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.clearAllMocks();
});

describe.each([
  {
    name: "products",
    useSearch: useProductsSearch,
    delay: 300,
    data: { products_page: undefined, memberships_page: undefined },
    only: ["products_data", "memberships_data", "has_products"],
    reset: ["products_data", "memberships_data"],
  },
  {
    name: "emails",
    useSearch: useEmailSearch,
    delay: 500,
    data: { page: undefined },
    only: ["installments", "pagination", "has_posts"],
    reset: ["installments"],
  },
])("$name search lifecycle", ({ useSearch, delay, data, only, reset }) => {
  const advance = (ms: number) => {
    act(() => {
      vi.advanceTimersByTime(ms);
    });
  };

  it("cancels an abandoned search when its page unmounts", () => {
    const { result, unmount } = renderHook(useSearch);
    act(() => {
      result.current.setQuery("abandoned search");
    });
    unmount();
    window.history.replaceState({}, "", "/settings");
    advance(delay + 1);
    expect(reload).not.toHaveBeenCalled();
  });

  it("keeps the existing debounce and reloads only the latest query while mounted", () => {
    const { result } = renderHook(useSearch);
    act(() => {
      result.current.setQuery("first");
    });
    advance(delay - 1);
    act(() => {
      result.current.setQuery("latest");
    });
    advance(delay - 1);
    expect(reload).not.toHaveBeenCalled();
    advance(1);
    expect(reload).toHaveBeenCalledExactlyOnceWith({ data: { ...data, query: "latest" }, only, reset });
  });

  it("initializes from the URL without reloading and clears the query and pagination normally", () => {
    window.history.replaceState({}, "", "/?query=initial");
    const { result } = renderHook(useSearch);
    expect(result.current.query).toBe("initial");
    advance(delay);
    expect(reload).not.toHaveBeenCalled();
    act(() => {
      result.current.setQuery("");
    });
    advance(delay);
    expect(reload).toHaveBeenCalledExactlyOnceWith({ data: { ...data, query: undefined }, only, reset });
  });

  it("still searches after Strict Mode replays cleanup", () => {
    const { result } = renderHook(useSearch, {
      wrapper: ({ children }) => <React.StrictMode>{children}</React.StrictMode>,
    });
    act(() => {
      result.current.setQuery("current");
    });
    advance(delay);
    expect(reload).toHaveBeenCalledExactlyOnceWith({ data: { ...data, query: "current" }, only, reset });
  });
});
