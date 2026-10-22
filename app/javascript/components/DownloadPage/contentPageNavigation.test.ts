// @vitest-environment happy-dom
import { afterEach, describe, expect, it } from "vitest";

import {
  CONTENT_PAGE_QUERY_PARAM,
  initialContentPageIndex,
  scrollWithinScrollableAncestor,
  urlWithContentPage,
} from "./contentPageNavigation";

const pages = [{ page_id: "page-a" }, { page_id: "page-b" }, { page_id: "page-c==" }];

const location = (search: string) => new URL(`https://gumroad.com/d/token${search}`);

describe("initialContentPageIndex", () => {
  // The URL is the only copy that survives a failed save, and the only one a bookmark or a shared
  // link carries, so it has to win over the value stored on the purchase.
  it("uses the page named in the URL over the page saved on the purchase", () => {
    expect(initialContentPageIndex(pages, location("?page=page-c=="), "page-b")).toBe(2);
  });

  it("falls back to the saved page when the URL names no page", () => {
    expect(initialContentPageIndex(pages, location(""), "page-b")).toBe(1);
  });

  it("falls back to the saved page when the URL names a page that no longer exists", () => {
    expect(initialContentPageIndex(pages, location("?page=deleted-page"), "page-c==")).toBe(2);
  });

  it("starts on the first page when neither the URL nor the purchase names one", () => {
    expect(initialContentPageIndex(pages, location(""), null)).toBe(0);
    expect(initialContentPageIndex(pages, location("?page=deleted-page"), null)).toBe(0);
    expect(initialContentPageIndex([], location("?page=page-a"), "page-a")).toBe(0);
  });
});

describe("urlWithContentPage", () => {
  it("adds the page and leaves the rest of the URL alone", () => {
    const url = location("?receipt=true&utm_source=email");

    const next = new URL(urlWithContentPage(url, "page-b"));

    expect(next.pathname).toBe("/d/token");
    expect(next.searchParams.get(CONTENT_PAGE_QUERY_PARAM)).toBe("page-b");
    expect(next.searchParams.get("receipt")).toBe("true");
    expect(next.searchParams.get("utm_source")).toBe("email");
  });

  it("replaces an existing page instead of appending a second one", () => {
    const next = new URL(urlWithContentPage(location("?page=page-a"), "page-b"));

    expect(next.searchParams.getAll(CONTENT_PAGE_QUERY_PARAM)).toEqual(["page-b"]);
  });
});

describe("scrollWithinScrollableAncestor", () => {
  afterEach(() => {
    document.body.innerHTML = "";
  });

  const rect = (top: number, height: number): DOMRect => ({
    x: 0,
    y: top,
    top,
    bottom: top + height,
    left: 0,
    right: 300,
    width: 300,
    height,
    toJSON: () => ({}),
  });

  const buildList = (containerTop: number, containerHeight: number, itemTop: number) => {
    const container = document.createElement("div");
    Object.defineProperty(container, "clientHeight", { value: containerHeight });
    Object.defineProperty(container, "scrollHeight", { value: 4000 });
    container.style.overflowY = "auto";
    container.getBoundingClientRect = () => rect(containerTop, containerHeight);

    const item = document.createElement("div");
    item.getBoundingClientRect = () => rect(itemTop, 56);

    container.appendChild(item);
    document.body.appendChild(container);
    return { container, item };
  };

  it("scrolls the list so an active page below the fold becomes visible", () => {
    const { container, item } = buildList(0, 400, 1700);

    expect(scrollWithinScrollableAncestor(item)).toBe(true);
    expect(container.scrollTop).toBe(1676);
  });

  it("leaves the list alone when the active page is already visible", () => {
    const { container, item } = buildList(0, 400, 120);

    expect(scrollWithinScrollableAncestor(item)).toBe(false);
    expect(container.scrollTop).toBe(0);
  });
});
