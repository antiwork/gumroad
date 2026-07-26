// @vitest-environment happy-dom

import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import HelpCenterArticle from "./Show";

type VisitOptions = { onCancel?: () => void; onError?: () => void };

const mocks = vi.hoisted(() => ({
  usePage: vi.fn(),
  routerGet: vi.fn<(url: string, data?: Record<string, never>, options?: VisitOptions) => void>(),
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

  it("scrolls to the passage a text-fragment link quotes", () => {
    // "Gumroad Discover" links at a paragraph of "Getting paid" by quoting its wording rather than
    // naming a heading id. getElementById cannot resolve that, so the reader used to stay at the
    // top of the destination article.
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#:~:text=For%20our%20review%2C%20we%20require%20your%20account%20to%20be%20legitimate`;

    const { container } = renderArticle({
      slug: "13-getting-paid",
      content: `<h3 id="${ANCHOR_ID}">Address verification</h3><p id="passage">For our review, we require your
                account to be legitimate in two major ways:</p>`,
    });

    expect(scrollIntoView).toHaveBeenCalled();
    expect(container.querySelector("#passage")).not.toBeNull();
  });

  it("ignores a text-fragment whose passage is not in the article", () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#:~:text=wording%20that%20is%20not%20here`;

    renderArticle({ slug: "13-getting-paid", content: `<p>For our review, we require your account.</p>` });

    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("skips the prefix and suffix context terms of a text-fragment", () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#:~:text=review-,we%20require%20your%20account,-legitimate`;

    const { container } = renderArticle({
      slug: "13-getting-paid",
      content: `<p>Before review</p><p id="passage">We require your account to be legitimate</p>`,
    });

    expect(scrollIntoView).toHaveBeenCalled();
    expect(container.querySelector("#passage")).not.toBeNull();
  });

  it("still navigates client-side to an article linked by a text-fragment, and scrolls to the passage once there", () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    const { container } = renderArticle({
      slug: "79-gumroad-discover",
      content: `<a id="cross" href="${GETTING_PAID_PATH}#:~:text=For%20our%20review">risk review process</a>`,
    });

    const event = clickLink(container, "#cross");

    expect(event.defaultPrevented).toBe(true);
    expect(mocks.routerGet.mock.calls[0]?.[0]).toBe(`${GETTING_PAID_PATH}#:~:text=For%20our%20review`);

    // Chromium hides a text directive from scripts once a history entry exists for it, and an
    // Inertia visit creates one, so the destination article renders with an EMPTY hash. The
    // directive has to come from what the click handler remembered, not from window.location.
    cleanup();
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}`;
    const destination = renderArticle({
      slug: "13-getting-paid",
      content: `<p id="passage">For our review, we require your account to be legitimate.</p>`,
    });

    expect(window.location.hash).toBe("");
    expect(scrollIntoView).toHaveBeenCalled();
    expect(destination.container.querySelector("#passage")).not.toBeNull();
  });

  it("does not scroll a later article to a passage from an abandoned navigation", () => {
    // If the reader clicks a text-fragment link and then goes somewhere else, the remembered
    // wording must not follow them around.
    const { container } = renderArticle({
      slug: "79-gumroad-discover",
      content: `<a id="cross" href="${GETTING_PAID_PATH}#:~:text=For%20our%20review">risk review process</a>`,
    });
    clickLink(container, "#cross");

    cleanup();
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}`;
    renderArticle({ slug: "13-getting-paid", content: `<p>For our review, we require your account.</p>` });

    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    cleanup();
    renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<p>For our review, we require your account.</p>`,
    });

    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("does not scroll an unrelated article the reader goes to after a cancelled text-fragment visit", () => {
    // The visit the reader clicked never renders — they navigate somewhere else instead. The
    // remembered wording is for a different article, so the one they do end up reading must be
    // left alone even though its text happens to contain the same words.
    const { container } = renderArticle({
      slug: "79-gumroad-discover",
      content: `<a id="cross" href="${GETTING_PAID_PATH}#:~:text=For%20our%20review">risk review process</a>`,
    });
    clickLink(container, "#cross");

    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    cleanup();
    window.location.href = `https://gumroad.com${PAYOUT_SETTINGS_PATH}`;
    renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<p>For our review, we require your account.</p>`,
    });

    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("forgets a text-fragment passage when the visit carrying it is cancelled", () => {
    // Cancelling means the destination article never renders, so a later visit to that same
    // article — arriving without any fragment — must not inherit the abandoned wording.
    const { container } = renderArticle({
      slug: "79-gumroad-discover",
      content: `<a id="cross" href="${GETTING_PAID_PATH}#:~:text=For%20our%20review">risk review process</a>`,
    });
    clickLink(container, "#cross");

    const options = mocks.routerGet.mock.calls[0]?.[2];
    expect(typeof options?.onCancel).toBe("function");
    options?.onCancel?.();

    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    cleanup();
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}`;
    renderArticle({
      slug: "13-getting-paid",
      content: `<p>For our review, we require your account.</p>`,
    });

    expect(scrollIntoView).not.toHaveBeenCalled();
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
