// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
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

const defaultProps = (): {
  results: Result[];
  pagination: { page: number; pages: number; from: number; to: number; count: number };
  creators: { id: string; name: string; count: number }[];
  bundles: { id: string; label: string }[];
  bundle_downloads: { id: string; label: string; download_url: string | null }[];
  archived_count: number;
  unarchived_count: number;
  search: SearchParams;
  purchase_analytics: Record<string, unknown>;
  receipt_purchases: { id: string; email: string; permalink: string; has_third_party_analytics: boolean }[];
} => ({
  results: [result("p1", "Alpha"), result("p2", "Beta")],
  pagination: { page: 1, pages: 3, from: 1, to: 2, count: 6 },
  creators: [
    { id: "c1", name: "Zoe", count: 3 },
    { id: "c2", name: "Ann", count: 3 },
  ],
  bundles: [{ id: "b1", label: "Bundle One" }],
  bundle_downloads: [],
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

type OnFinish = () => void;

// router.get is a vi.fn, so its recorded options are untyped; narrow rather than assert.
const isOnFinish = (value: unknown): value is OnFinish => typeof value === "function";

const lastOnFinish = (): OnFinish => {
  const call = mocks.routerGet.mock.calls.at(-1);
  if (!call) throw new Error("expected router.get to have been called");
  const options: unknown = call[2];
  if (typeof options !== "object" || options === null || !("onFinish" in options))
    throw new Error("expected router.get options with an onFinish");
  const { onFinish } = options;
  if (!isOnFinish(onFinish)) throw new Error("expected onFinish to be a function");
  return onFinish;
};

const settleLastVisit = () => {
  lastOnFinish()();
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
      expect.objectContaining({ preserveState: true, preserveScroll: true }),
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

  it("hands the filter controls back to the server's props once the visit settles", () => {
    renderPage();

    fireEvent.click(creatorCheckbox("Zoe"));
    expect(creatorCheckbox("Zoe").checked).toBe(true);

    // The server ignored the id, so its echoed props win over the optimistic tick.
    act(() => settleLastVisit());
    expect(creatorCheckbox("Zoe").checked).toBe(false);
  });

  it("releases the optimistic filter state when an archive reload displaces the visit", () => {
    renderPage();

    fireEvent.click(creatorCheckbox("Zoe"));
    expect(creatorCheckbox("Zoe").checked).toBe(true);

    // router.reload() from an archive/delete interrupts the filter visit and echoes the old
    // search, so the only settle signal is this one — the checkbox must not stay stranded.
    act(() => settleLastVisit());
    expect(creatorCheckbox("Zoe").checked).toBe(false);
  });

  it("hides the archived-purchases banner as soon as the archived filter is clicked", () => {
    renderPage();

    expect(screen.getByRole("status").textContent).toContain("You have 2 archived purchases");

    const archivedLabel = screen.getByText("Show archived only").closest("label");
    if (!archivedLabel) throw new Error("expected the archived filter label");
    fireEvent.click(archivedLabel.querySelector("input") ?? archivedLabel);

    // The banner invites you into the archive, so it must not survive alongside a ticked
    // "Show archived only" while the request is in flight.
    expect(screen.queryByRole("status")).toBeNull();
  });

  it("keeps the newer click's params when a superseded visit settles", () => {
    renderPage();

    fireEvent.click(creatorCheckbox("Ann"));
    const supersededVisit = lastOnFinish();
    fireEvent.click(creatorCheckbox("Zoe"));

    // Inertia fires onFinish for the visit the second click interrupted; honouring it would
    // discard Ann and put us back at the bug.
    act(() => supersededVisit());
    expect(creatorCheckbox("Ann").checked).toBe(true);

    fireEvent.click(creatorCheckbox("Zoe"));
    expect(lastGetParams()).toEqual({ sort: "recently_updated", creators: "c2" });
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
      // Paging scrolls to the top; a filter change keeps the buyer's scroll position.
      expect.objectContaining({ preserveState: true, preserveScroll: false }),
    );

    // A filter change navigates without a page param, i.e. back to page 1.
    fireEvent.change(screen.getByLabelText("Sort by"), { target: { value: "purchase_date" } });
    expect(lastGetParams()).toEqual({ sort: "purchase_date" });
  });

  it("renders a bundle Download all link when the selected bundle archive is ready", () => {
    const props = defaultProps();
    props.bundle_downloads = [{ id: "b1", label: "Bundle One", download_url: "/d/bundle-token/download_archive" }];
    renderPage(props);

    expect(screen.getByText(/Download everything included in/u).textContent).toContain(
      "Download everything included in",
    );
    const link = screen.getByRole("link", { name: /Download all/u });
    expect(link.getAttribute("href")).toBe("/d/bundle-token/download_archive");
  });

  it("shows the bundle ZIP preparation state while the archive is being generated", () => {
    const props = defaultProps();
    props.bundle_downloads = [{ id: "b1", label: "Bundle One", download_url: null }];
    renderPage(props);

    const button = screen.getByRole("button", { name: /Preparing ZIP/u });
    if (!(button instanceof HTMLButtonElement)) throw new Error("expected a button");
    expect(button.disabled).toBe(true);
  });
});

describe("removal copy", () => {
  it("offers removal rather than permanent deletion, and says the card can come back", () => {
    renderPage();

    const card = screen.getAllByRole("button", { name: "Open product action menu" })[0];
    if (!card) throw new Error("expected a product card menu");
    fireEvent.click(card);

    fireEvent.click(screen.getByText("Remove from library"));

    expect(screen.getByText(/from your library\?/u)).toBeTruthy();
    expect(screen.getByText(/our support team can put the card back/u)).toBeTruthy();
    // `is_deleted_by_buyer` is reversible, so copy claiming otherwise is the defect
    // (gumroad-private#1762).
    expect(screen.queryByText(/permanently/iu)).toBeNull();
    expect(screen.queryByText(/cannot be undone/iu)).toBeNull();
  });
});
