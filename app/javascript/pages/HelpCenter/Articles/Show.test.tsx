// @vitest-environment happy-dom

import { act, cleanup, render } from "@testing-library/react";
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

// The component scrolls inside requestAnimationFrame, deliberately: Inertia resets the scroll
// container to the top after a visit and does it after the effect runs, so scrolling in the effect
// itself gets undone. Tests therefore have to let a frame pass before asserting.
const flushFrames = async () => {
  await act(async () => {
    await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
  });
};

const clickLink = (container: HTMLElement, selector: string) => {
  const link = container.querySelector<HTMLAnchorElement>(selector);
  if (!link) throw new Error(`no link matching ${selector}`);
  const event = new MouseEvent("click", { bubbles: true, cancelable: true });
  link.dispatchEvent(event);
  return event;
};

// happy-dom has no ResizeObserver and never lays anything out, so stand one in and drive it by
// hand. Calling resizeObserved() plays the part of an article image finishing loading and making
// the article taller.
const resizeCallbacks = new Set<ResizeObserverCallback>();

class FakeResizeObserver implements ResizeObserver {
  constructor(private readonly callback: ResizeObserverCallback) {
    resizeCallbacks.add(callback);
  }
  observe() {}
  unobserve() {}
  disconnect() {
    resizeCallbacks.delete(this.callback);
  }
}
window.ResizeObserver = FakeResizeObserver;
globalThis.ResizeObserver = FakeResizeObserver;

const resizeObserved = () => {
  act(() => {
    // Snapshot first: constructing the observer we hand the callback registers it again.
    for (const callback of [...resizeCallbacks]) callback([], new FakeResizeObserver(callback));
  });
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

  it("scrolls to the fragment target once the article HTML is in the document", async () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#${ANCHOR_ID}`;

    renderArticle({
      slug: "13-getting-paid",
      content: `<h3 id="${ANCHOR_ID}">Address verification</h3>`,
    });

    await flushFrames();

    expect(scrollIntoView).toHaveBeenCalled();
    expect(document.getElementById(ANCHOR_ID)).not.toBeNull();
  });

  it("scrolls after Inertia has reset the scroll position, not before", async () => {
    // Inertia resets the scroll container to the top once a visit completes, and it does that after
    // this component's effects have run. Scrolling straight from the effect therefore looked right
    // for one frame and was then undone — the reader ended up at the top of the article they had
    // deep-linked into. Pin the ordering: nothing may scroll before the reset, and the target must
    // be scrolled to after it.
    const order: string[] = [];
    Element.prototype.scrollIntoView = vi.fn(() => order.push("scrollIntoView"));
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#${ANCHOR_ID}`;

    renderArticle({ slug: "13-getting-paid", content: `<h3 id="${ANCHOR_ID}">Address verification</h3>` });

    // Stands in for Inertia's post-visit scroll reset.
    order.push("inertia-scroll-reset");
    expect(order).toEqual(["inertia-scroll-reset"]);

    await flushFrames();

    expect(order).toEqual(["inertia-scroll-reset", "scrollIntoView"]);
  });

  it("scrolls to the target again while the article is still growing", async () => {
    // Article images carry no width or height, so the browser re-lays out the article as each one
    // loads and the target drifts away from where we scrolled to. On a real preview load of
    // "Getting paid" that left the heading 140px above the top of the viewport — just out of sight.
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#${ANCHOR_ID}`;

    renderArticle({ slug: "13-getting-paid", content: `<h3 id="${ANCHOR_ID}">Address verification</h3>` });

    await flushFrames();
    expect(scrollIntoView).toHaveBeenCalledTimes(1);

    resizeObserved();

    expect(scrollIntoView).toHaveBeenCalledTimes(2);
  });

  it("stops correcting the scroll position once the reader scrolls themselves", async () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#${ANCHOR_ID}`;

    renderArticle({ slug: "13-getting-paid", content: `<h3 id="${ANCHOR_ID}">Address verification</h3>` });

    await flushFrames();
    expect(scrollIntoView).toHaveBeenCalledTimes(1);

    window.dispatchEvent(new Event("wheel"));
    resizeObserved();

    expect(scrollIntoView).toHaveBeenCalledTimes(1);
  });

  it("stops correcting the scroll position after the article has had time to settle", async () => {
    // Only the timers are faked: flushFrames needs requestAnimationFrame to keep working.
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
    try {
      const scrollIntoView = vi.fn();
      Element.prototype.scrollIntoView = scrollIntoView;
      window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#${ANCHOR_ID}`;

      renderArticle({ slug: "13-getting-paid", content: `<h3 id="${ANCHOR_ID}">Address verification</h3>` });

      await flushFrames();
      expect(scrollIntoView).toHaveBeenCalledTimes(1);

      act(() => void vi.advanceTimersByTime(5000));
      resizeObserved();

      expect(scrollIntoView).toHaveBeenCalledTimes(1);
    } finally {
      vi.useRealTimers();
    }
  });

  it("handles a percent-encoded fragment", async () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#Address%20verification`;

    renderArticle({
      slug: "13-getting-paid",
      content: `<h3 id="Address verification">Address verification</h3>`,
    });

    await flushFrames();

    expect(scrollIntoView).toHaveBeenCalled();
  });

  it("scrolls to the passage a text-fragment link quotes", async () => {
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

    await flushFrames();

    expect(scrollIntoView).toHaveBeenCalled();
    expect(container.querySelector("#passage")).not.toBeNull();
  });

  it("ignores a text-fragment whose passage is not in the article", async () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#:~:text=wording%20that%20is%20not%20here`;

    renderArticle({ slug: "13-getting-paid", content: `<p>For our review, we require your account.</p>` });

    await flushFrames();

    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("skips the prefix and suffix context terms of a text-fragment", async () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}#:~:text=review-,we%20require%20your%20account,-legitimate`;

    const { container } = renderArticle({
      slug: "13-getting-paid",
      content: `<p>Before review</p><p id="passage">We require your account to be legitimate</p>`,
    });

    await flushFrames();

    expect(scrollIntoView).toHaveBeenCalled();
    expect(container.querySelector("#passage")).not.toBeNull();
  });

  it("still navigates client-side to an article linked by a text-fragment, and scrolls to the passage once there", async () => {
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
    await flushFrames();

    expect(scrollIntoView).toHaveBeenCalled();
    expect(destination.container.querySelector("#passage")).not.toBeNull();
  });

  it("does not scroll a later article to a passage from an abandoned navigation", async () => {
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

    await flushFrames();

    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("does not scroll an unrelated article the reader goes to after a cancelled text-fragment visit", async () => {
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

    await flushFrames();

    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("forgets a text-fragment passage when the visit carrying it is cancelled", async () => {
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

    await flushFrames();

    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("keeps the second passage when a new text-fragment click cancels the visit still in flight", async () => {
    // Starting a visit cancels any visit still in flight, and Inertia does that synchronously from
    // inside router.get — so the first visit's cancellation callback runs after the second click
    // has already remembered its wording. The reader is heading to the second article, so that is
    // the wording that has to survive.
    window.location.href = `https://gumroad.com/help/article/79-gumroad-discover`;
    const { container } = renderArticle({
      slug: "79-gumroad-discover",
      content: `
        <a id="first" href="${GETTING_PAID_PATH}#:~:text=For%20our%20review">risk review process</a>
        <a id="second" href="${PAYOUT_SETTINGS_PATH}#:~:text=no%20P.O.%20boxes">payout address</a>
      `,
    });

    clickLink(container, "#first");
    clickLink(container, "#second");
    // What Inertia does inside the second router.get: cancel the first visit.
    mocks.routerGet.mock.calls[0]?.[2]?.onCancel?.();

    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    cleanup();
    window.location.href = `https://gumroad.com${PAYOUT_SETTINGS_PATH}`;
    const destination = renderArticle({
      slug: "260-your-payout-settings-page",
      content: `<p>A physical address is required.</p><p id="passage">We accept no P.O. boxes here.</p>`,
    });

    await flushFrames();

    expect(scrollIntoView).toHaveBeenCalled();
    expect(scrollIntoView.mock.instances[0]).toBe(destination.container.querySelector("#passage"));
  });

  it("does nothing when there is no fragment", async () => {
    const scrollIntoView = vi.fn();
    Element.prototype.scrollIntoView = scrollIntoView;
    window.location.href = `https://gumroad.com${GETTING_PAID_PATH}`;

    renderArticle({
      slug: "13-getting-paid",
      content: `<h3 id="${ANCHOR_ID}">Address verification</h3>`,
    });

    await flushFrames();

    expect(scrollIntoView).not.toHaveBeenCalled();
  });
});
