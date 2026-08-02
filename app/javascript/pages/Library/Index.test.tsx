// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";
import { UserAgentProvider } from "$app/components/UserAgent";

import LibraryPage, { Result, SearchParams } from "./Index";

const mocks = vi.hoisted(() => ({
  routerGet: vi.fn(),
  routerReload: vi.fn(),
  routerReplace: vi.fn(),
  usePage: vi.fn(),
}));

vi.mock("@inertiajs/react", () => ({
  router: { get: mocks.routerGet, reload: mocks.routerReload, replace: mocks.routerReplace },
  usePage: mocks.usePage,
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/data/library", () => ({ deletePurchasedProduct: vi.fn(), setPurchaseArchived: vi.fn() }));
// Filters live behind a breakpoint check that reads CSS variables happy-dom doesn't have.
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));

beforeAll(() => {
  Object.assign(globalThis, {
    Routes: new Proxy({}, { get: (_target, name: string) => () => `/${String(name).replace(/_path$|_url$/u, "")}` }),
  });
});

afterEach(cleanup);
beforeEach(() => {
  mocks.routerGet.mockReset();
  mocks.routerReload.mockReset();
  mocks.routerReplace.mockReset();
});

const result = (id: string, name: string): Result => ({
  product: {
    name,
    creator: { name: `${name} creator`, profile_url: `https://example.com/${id}`, avatar_url: null },
    thumbnail_url: null,
    native_type: "digital",
  },
  purchase: { id, is_archived: false, download_url: `https://example.com/d/${id}`, variants: null },
});

const defaultSearch = (): SearchParams => ({
  sort: "recently_updated",
  query: "",
  creators: [],
  bundles: [],
  show_archived_only: false,
});

const defaultProps = () => ({
  results: [result("p1", "Alpha"), result("p2", "Beta")],
  pagination: { page: 1, pages: 3, from: 1, to: 2, count: 6 },
  creators: [
    { id: "c1", name: "Zoe", count: 3 },
    { id: "c2", name: "Ann", count: 3 },
  ],
  bundles: [{ id: "b1", label: "Bundle One" }],
  archived_count: 2,
  unarchived_count: 6,
  search: defaultSearch(),
  purchase_analytics: {},
  receipt_purchases: [],
});

const renderPage = (props = defaultProps()) => {
  mocks.usePage.mockReturnValue({ props });
  return render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "app.test",
        rootDomain: "test",
        shortDomain: "short.test",
        discoverDomain: "discover.test",
        thirdPartyAnalyticsDomain: "analytics.test",
        apiDomain: "api.test",
      }}
    >
      <LoggedInUserProvider value={null}>
        <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
          <LibraryPage />
        </UserAgentProvider>
      </LoggedInUserProvider>
    </DomainSettingsProvider>,
  );
};

const creatorCheckbox = (name: string): HTMLInputElement => {
  const input = screen.getByText(name).closest("label")?.querySelector("input");
  if (!input) throw new Error(`expected a checkbox for creator ${name}`);
  return input;
};

const lastGetParams = (): Record<string, string> => {
  const call = mocks.routerGet.mock.calls.at(-1);
  if (!call) throw new Error("expected router.get to have been called");
  const params: unknown = call[1];
  if (typeof params !== "object" || params === null) throw new Error("expected router.get params object");
  return Object.fromEntries(Object.entries(params).map(([key, value]) => [key, String(value)]));
};

describe("LibraryPage", () => {
  it("renders the server-supplied page verbatim, without re-slicing", () => {
    const props = defaultProps();
    // A page-2-shaped payload: the counts say there are 6 products, but only these two were
    // sent. The old client sliced a full in-memory array; the new one must trust the server.
    props.pagination = { page: 2, pages: 3, from: 3, to: 4, count: 6 };
    renderPage(props);

    expect(screen.getByText("Alpha")).toBeTruthy();
    expect(screen.getByText("Beta")).toBeTruthy();
    expect(screen.getByText("Showing 3-4 of 6 products")).toBeTruthy();
    expect(mocks.routerGet).not.toHaveBeenCalled();
  });

  it("navigates with the sort param when the sort select changes", () => {
    renderPage();

    fireEvent.change(screen.getByLabelText("Sort by"), { target: { value: "purchase_date" } });

    expect(mocks.routerGet).toHaveBeenCalledTimes(1);
    expect(mocks.routerGet).toHaveBeenCalledWith(
      "/library",
      { sort: "purchase_date" },
      { preserveState: true, preserveScroll: true },
    );
  });

  it("navigates with the query param when a search is committed with Enter", () => {
    renderPage();

    const input = screen.getByPlaceholderText("Search products");
    fireEvent.change(input, { target: { value: "guitar" } });
    expect(mocks.routerGet).not.toHaveBeenCalled();

    fireEvent.keyDown(input, { key: "Enter" });
    expect(lastGetParams()).toEqual({ sort: "recently_updated", query: "guitar" });
  });

  it("adds a creator to the comma-separated creators param", () => {
    const props = defaultProps();
    props.search.creators = ["c1"];
    renderPage(props);

    const annLabel = screen.getByText("Ann").closest("label");
    if (!annLabel) throw new Error("expected a label for creator Ann");
    fireEvent.click(annLabel.querySelector("input") ?? annLabel);

    // Same URL vocabulary the old client wrote to the address bar, so bookmarks keep working.
    expect(lastGetParams()).toEqual({ sort: "recently_updated", creators: "c1,c2" });
  });

  it("composes creator selections made before the server echoes the first one back", () => {
    renderPage();

    // No props arrive between the two clicks: the second must build on the first, and the
    // first checkbox must stay checked while its request is in flight.
    fireEvent.click(creatorCheckbox("Ann"));
    fireEvent.click(creatorCheckbox("Zoe"));

    expect(lastGetParams()).toEqual({ sort: "recently_updated", creators: "c2,c1" });
    expect(creatorCheckbox("Ann").checked).toBe(true);
  });

  it("unchecks a creator selected optimistically when it is clicked again", () => {
    renderPage();

    fireEvent.click(creatorCheckbox("Zoe"));
    expect(creatorCheckbox("Zoe").checked).toBe(true);

    fireEvent.click(creatorCheckbox("Zoe"));
    expect(creatorCheckbox("Zoe").checked).toBe(false);
    expect(lastGetParams()).toEqual({ sort: "recently_updated" });
  });

  it("preserves bundle and archived params and omits empty ones when toggling a filter", () => {
    const props = defaultProps();
    props.search.bundles = ["b1"];
    renderPage(props);

    const archivedLabel = screen.getByText("Show archived only").closest("label");
    if (!archivedLabel) throw new Error("expected the archived filter label");
    fireEvent.click(archivedLabel.querySelector("input") ?? archivedLabel);

    expect(lastGetParams()).toEqual({ sort: "recently_updated", bundles: "b1", show_archived_only: "true" });
  });

  it("emits the page param on pagination and resets it when filters change", () => {
    renderPage();

    fireEvent.click(screen.getByRole("button", { name: "2" }));
    expect(mocks.routerGet).toHaveBeenCalledWith(
      "/library",
      { sort: "recently_updated", page: "2" },
      { preserveState: true, preserveScroll: false },
    );

    // A filter change navigates without a page param, i.e. back to page 1.
    fireEvent.change(screen.getByLabelText("Sort by"), { target: { value: "purchase_date" } });
    expect(lastGetParams()).toEqual({ sort: "purchase_date" });
  });
});
