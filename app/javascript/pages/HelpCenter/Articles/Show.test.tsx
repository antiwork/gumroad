// @vitest-environment happy-dom

import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import HelpCenterArticle from "./Show";

const mocks = vi.hoisted(() => ({
  usePage: vi.fn(),
  routerGet: vi.fn(),
}));

vi.mock("@inertiajs/react", () => ({
  usePage: mocks.usePage,
  router: { get: mocks.routerGet },
  Link: ({ children, href }: { children: React.ReactNode; href: string }) => <a href={href}>{children}</a>,
}));

vi.mock("../Layout", () => ({
  HelpCenterLayout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("$app/components/HelpCenterPage/CategorySidebar", () => ({
  CategorySidebar: () => <nav />,
}));

const GETTING_PAID_PATH = "/help/article/13-getting-paid";
const PAYOUT_SETTINGS_PATH = "/help/article/260-your-payout-settings-page";
const ANCHOR_ID = "Address-verification-dK7mR";

const renderArticle = ({ slug, content }: { slug: string; content: string }) => {
  mocks.usePage.mockReturnValue({
    url: window.location.pathname,
    props: {
      article: { title: "Article", slug, content, category: { slug: "getting-paid", title: "Getting paid", url: "/" } },
      sidebar_categories: [],
    },
  });
  return render(<HelpCenterArticle />);
};

const clickLink = (container: HTMLElement, selector: string) => {
  const link = container.querySelector<HTMLAnchorElement>(selector);
  if (!link) throw new Error(`no link matching ${selector}`);
  const event = new MouseEvent("click", { bubbles: true, cancelable: true });
  link.dispatchEvent(event);
  return event;
};

describe("HelpCenterArticle", () => {
  beforeEach(() => {
    window.location.href = `https://gumroad.com${PAYOUT_SETTINGS_PATH}`;
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("keeps the fragment when navigating to a section of another article", () => {
    const { container } = renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<a id="cross" href="${GETTING_PAID_PATH}#${ANCHOR_ID}">Address verification</a>`,
    });

    const event = clickLink(container, "#cross");

    expect(event.defaultPrevented).toBe(true);
    expect(mocks.routerGet).toHaveBeenCalledWith(`${GETTING_PAID_PATH}#${ANCHOR_ID}`);
  });

  it("does not call a hook while handling the click", () => {
    // usePage() is a React hook, so reading it from inside the click handler throws
    // "invalid hook call" and takes the whole interceptor down with it — preventDefault never
    // runs and the click falls through to a full page load.
    const { container } = renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<a id="cross" href="${GETTING_PAID_PATH}#${ANCHOR_ID}">Address verification</a>`,
    });
    const callsAfterRender = mocks.usePage.mock.calls.length;

    clickLink(container, "#cross");

    expect(mocks.usePage.mock.calls.length).toBe(callsAfterRender);
  });

  it("navigates to a fragment-less internal article unchanged", () => {
    const { container } = renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<a id="cross" href="${GETTING_PAID_PATH}">Getting paid</a>`,
    });

    clickLink(container, "#cross");

    expect(mocks.routerGet).toHaveBeenCalledWith(GETTING_PAID_PATH);
  });

  it("leaves same-article anchor links to the browser", () => {
    const { container } = renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<a id="same" href="${PAYOUT_SETTINGS_PATH}#Requirements">Requirements</a>`,
    });

    const event = clickLink(container, "#same");

    expect(event.defaultPrevented).toBe(false);
    expect(mocks.routerGet).not.toHaveBeenCalled();
  });

  it("ignores links that leave the help center", () => {
    const { container } = renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<a id="external" href="https://stripe.com/docs">Stripe</a><a id="app" href="/dashboard">Dashboard</a>`,
    });

    const externalEvent = clickLink(container, "#external");
    const appEvent = clickLink(container, "#app");

    expect(externalEvent.defaultPrevented).toBe(false);
    expect(appEvent.defaultPrevented).toBe(false);
    expect(mocks.routerGet).not.toHaveBeenCalled();
  });

  it("scrolls to the fragment target once the article HTML is in the document", () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#${ANCHOR_ID}`;

    renderArticle({
      slug: "13-getting-paid",
      content: `<h3 id="${ANCHOR_ID}">Address verification</h3>`,
    });

    expect(scrollIntoView).toHaveBeenCalled();
    expect(document.getElementById(ANCHOR_ID)).not.toBeNull();
  });

  it("handles a percent-encoded fragment", () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#Address%20verification`;

    renderArticle({
      slug: "13-getting-paid",
      content: `<h3 id="Address verification">Address verification</h3>`,
    });

    expect(scrollIntoView).toHaveBeenCalled();
  });

  it("does nothing when there is no fragment", () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}`;

    renderArticle({
      slug: "13-getting-paid",
      content: `<h3 id="${ANCHOR_ID}">Address verification</h3>`,
    });

    expect(scrollIntoView).not.toHaveBeenCalled();
  });
});
