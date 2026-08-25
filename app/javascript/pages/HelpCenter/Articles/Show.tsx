import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { CategorySidebar } from "$app/components/HelpCenterPage/CategorySidebar";
import { mountHelpVideos } from "$app/components/HelpCenterPage/mountHelpVideos";
import { ArticleCategory, SidebarCategory } from "$app/components/HelpCenterPage/types";

import { HelpCenterLayout } from "../Layout";

interface Article {
  title: string;
  slug: string;
  content: string;
  category: ArticleCategory;
}

interface Props {
  article: Article;
  sidebar_categories: SidebarCategory[];
}

// A URL fragment does not have to be an element id. It can also be a browser "text directive",
// written "#:~:text=[prefix-,]start[,end][,-suffix]", which asks the browser to find and scroll to
// a passage by its wording instead — one help article uses this to point at a paragraph of
// another. Browsers only act on a text directive when they load a document, so it does nothing on
// an Inertia visit, and even on a fresh page load the passage is not in the document yet (the
// article body is injected as raw HTML by this component). Both cases need us to do the search.
// Returns the wording to look for, or null if the fragment is not a text directive we understand.
const textDirectiveTerm = (fragment: string): string | null => {
  if (!fragment.startsWith(":~:")) return null;

  const textDirective = fragment
    .slice(":~:".length)
    .split("&")
    .find((directive) => directive.startsWith("text="));
  if (!textDirective) return null;

  // The passage itself is the first comma-separated term that is not context: a "prefix-" term
  // ends with a dash, a "-suffix" term starts with one. We only search for the passage's start,
  // which is enough to know where to scroll to.
  const passage = textDirective
    .slice("text=".length)
    .split(",")
    .find((term) => term.length > 0 && !term.endsWith("-") && !term.startsWith("-"));
  if (!passage) return null;

  try {
    return decodeURIComponent(passage);
  } catch {
    // A malformed escape sequence means the term isn't encoded — use it as-is.
    return passage;
  }
};

// Browsers deliberately hide a text directive from scripts: as soon as a history entry is created
// for a URL that contains one — an ordinary page load, but also a History API update like the ones
// Inertia does — Chromium strips the ":~:..." part out of `location.href`/`location.hash` so a page
// cannot read what wording sent the reader to it. That means we cannot recover the directive after
// the visit; we have to remember it at the moment we handle the click, which is the last point at
// which we can see it. This lives outside the component because Inertia may re-mount the page
// component between the click and the render of the destination article, which would throw away a
// ref, and it is a single value because only one navigation is ever in flight.
//
// The article path the reader was heading to is remembered alongside the wording, because the visit
// may never reach that article: it can be cancelled, redirected elsewhere, or fail. Without the
// path, wording left over from such a visit would be picked up by whichever article the reader read
// next and scroll them to an unrelated passage that happened to match.
let textDirectivePendingScroll: { path: string; passage: string } | null = null;

// The one place a hidden text directive survives: the performance entry that records how this
// document was loaded. Its `name` is the URL the browser was asked for, recorded before the
// directive is stripped out of `location`, so opening or reloading a text-fragment URL directly —
// where no click of ours ran and there is nothing remembered — can still be resolved from here.
// This is the direct-load case: the browser does its own text-fragment scrolling on a normal page,
// but an article body arrives as raw HTML after render, so by the time the passage exists the
// browser has long given up and only we can scroll to it.
//
// Read at most once. The entry describes how the document was loaded and never changes, so the
// path check alone is not enough: a reader who lands on an article by text-fragment URL, reads on,
// and later comes BACK to that same article arrives with no fragment but a still-matching path,
// and would be scrolled to the passage they read earlier instead of the top. Spending the entry on
// first use makes it what it is meant to be — how the reader got here, once.
let pageLoadTextDirectiveTaken = false;

const textDirectiveFromPageLoad = (): string | null => {
  if (pageLoadTextDirectiveTaken) return null;

  // A document restored from the back/forward cache has no fresh navigation entry, and neither
  // does a test environment that never navigated; neither is worth failing over.
  const navigation = performance.getEntriesByType("navigation")[0];
  if (!navigation) return null;

  let loadedUrl;
  try {
    loadedUrl = new URL(navigation.name);
  } catch {
    return null;
  }
  // Only act on it if this is still the article that URL named. Inertia visits do not create a new
  // navigation entry, so after a client-side visit away this entry still describes the article the
  // reader arrived on and its wording must not follow them.
  if (loadedUrl.pathname !== window.location.pathname) return null;

  const passage = textDirectiveTerm(loadedUrl.hash.slice(1));
  if (passage === null) return null;

  pageLoadTextDirectiveTaken = true;
  return passage;
};

// Firefox and Safari do not implement text directives at all, so nothing strips them and the
// fragment is still readable after a plain page load. Read whichever source has it.
const takePendingTextDirective = (fragment: string): string | null => {
  const pending = textDirectivePendingScroll;
  textDirectivePendingScroll = null;
  if (pending?.path === window.location.pathname) return pending.passage;
  return textDirectiveTerm(fragment) ?? textDirectiveFromPageLoad();
};

// Finds the smallest element whose text contains the given wording, so we scroll as close to the
// passage as possible rather than to the whole article. Whitespace and case are ignored because
// the wording in a link is written by hand and the HTML wraps and indents freely.
const elementContainingText = (root: HTMLElement, text: string): HTMLElement | null => {
  const normalize = (value: string) => value.replace(/\s+/gu, " ").trim().toLowerCase();
  const needle = normalize(text);
  if (!needle) return null;

  let match: HTMLElement | null = null;
  let candidate: HTMLElement | null = root;
  while (candidate && normalize(candidate.textContent).includes(needle)) {
    match = candidate;
    candidate =
      [...candidate.children].find(
        (child): child is HTMLElement => child instanceof HTMLElement && normalize(child.textContent).includes(needle),
      ) ?? null;
  }

  return match === root ? null : match;
};

export default function HelpCenterArticle() {
  const { article, sidebar_categories } = typia.assert<Props>(usePage().props);
  const contentRef = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    const container = contentRef.current;
    if (!container) return;

    // Intercept clicks on internal help links to use Inertia navigation instead of full page reload
    const onLinkClick = (e: MouseEvent) => {
      if (!(e.target instanceof HTMLElement)) return;
      const linkElement = e.target.closest("a");
      if (!linkElement) return;

      const resolvedUrl = new URL(linkElement.href);
      if (resolvedUrl.origin !== window.location.origin || !resolvedUrl.pathname.startsWith("/help/")) return;

      // A link to a section of the article we're already on needs no navigation at all — let the
      // browser do its native jump to the anchor.
      if (resolvedUrl.pathname === window.location.pathname && resolvedUrl.hash.length > 0) return;

      e.preventDefault();
      // Remember a text directive before navigating, because the browser will hide it from us
      // afterwards (see takePendingTextDirective).
      const passage = textDirectiveTerm(resolvedUrl.hash.slice(1));
      const pending = passage === null ? null : { path: resolvedUrl.pathname, passage };
      textDirectivePendingScroll = pending;
      // Carry the fragment through the Inertia visit. Articles deep-link into each other's
      // sections (for example the payout settings requirements point at "Address verification" in
      // "Getting paid"), and navigating to the pathname alone silently drops the "#section" part,
      // dumping the reader at the top of the destination article instead.
      const url = `${resolvedUrl.pathname}${resolvedUrl.hash}`;
      if (pending === null) {
        router.get(url);
      } else {
        // A cancelled or failed visit never renders the article that would consume the remembered
        // wording, so forget it here instead of leaving it behind for a later visit to that same
        // article to act on.
        //
        // Only forget this visit's own wording. Starting a visit cancels any visit still in
        // flight, and Inertia runs that cancellation synchronously from inside `router.get` — so
        // when a reader clicks a second text-fragment link before the first visit arrives, the
        // first visit's callback fires *after* the second click has already stored its wording.
        // Clearing unconditionally would throw away the wording the reader is currently heading
        // to, and a hidden directive cannot be recovered from the URL afterwards, so they would
        // land at the top of the article they just asked for.
        const forget = () => {
          if (textDirectivePendingScroll === pending) textDirectivePendingScroll = null;
        };
        router.get(url, {}, { onCancel: forget, onError: forget });
      }
    };

    container.addEventListener("click", onLinkClick);
    return () => container.removeEventListener("click", onLinkClick);
  }, []);

  React.useEffect(() => {
    const container = contentRef.current;
    if (!container) return;
    return mountHelpVideos(container);
  }, [article.slug, article.content]);

  // The article body is injected as raw HTML, so the headings a fragment points at don't exist
  // until this component has rendered. Both the browser (on a fresh page load) and Inertia (on a
  // client-side visit) try to jump to the fragment before that happens and give up, leaving the
  // reader at the top, so do the scrolling here once the target is actually in the document.
  React.useEffect(() => {
    const fragment = window.location.hash.slice(1);

    // A text directive we captured from the click that brought the reader here, or one still
    // present in the URL on browsers that do not hide it. Checked before the empty-fragment case
    // below, because a hidden directive leaves the hash empty.
    const passage = takePendingTextDirective(fragment);

    let id: string | null = null;
    if (passage === null) {
      // Nothing to scroll to.
      if (!fragment) return;

      id = fragment;
      try {
        id = decodeURIComponent(fragment);
      } catch {
        // A malformed escape sequence means the fragment isn't encoded — use it as-is.
      }
    }

    // Scroll on the next frame rather than right now. Inertia resets the scroll container to the
    // top after a visit, and it does that *after* this effect runs, so scrolling here directly
    // gets undone: the reader sees the right passage for one frame and then the top of the
    // article. (An element-id fragment survived that reset only because Inertia's own hash
    // handling scrolled a second time afterwards; a text directive leaves an empty hash, so
    // nothing came along to repeat it and the reset won.) Waiting a frame puts our scroll last.
    const scroll = () => {
      const target =
        passage === null
          ? document.getElementById(id ?? "")
          : contentRef.current && elementContainingText(contentRef.current, passage);
      target?.scrollIntoView();
    };
    const frame = requestAnimationFrame(scroll);

    // Scrolling once is not enough. The images in an article body carry no width or height, so the
    // browser only learns how tall they are as each one finishes loading, and it lays the article
    // out again every time. Those reflows move the target after we already scrolled to it: on a
    // fresh load of "Getting paid" the heading came to rest 140px above the top of the viewport,
    // just out of sight, which reads to the reader as landing in the wrong place.
    //
    // So keep the target in view for as long as the article's height is still settling. Two things
    // end that: the reader taking over (we must never fight their own scrolling), and a short grace
    // period, after which any further height change belongs to something other than the initial
    // load and re-scrolling would be an unwanted jump.
    const content = contentRef.current;
    const RESETTLE_WINDOW_MS = 3000;
    const INTERACTION_EVENTS = ["wheel", "touchstart", "keydown", "pointerdown"] as const;

    let observer: ResizeObserver | null = null;
    const stopResettling = () => {
      observer?.disconnect();
      observer = null;
      clearTimeout(timer);
      for (const event of INTERACTION_EVENTS) window.removeEventListener(event, stopResettling);
    };
    const timer = setTimeout(stopResettling, RESETTLE_WINDOW_MS);

    // ResizeObserver is missing in some test environments; the scroll above still happens without it.
    if (typeof ResizeObserver !== "undefined" && content) {
      observer = new ResizeObserver(() => scroll());
      observer.observe(content);
    }
    for (const event of INTERACTION_EVENTS) window.addEventListener(event, stopResettling, { passive: true });

    return () => {
      cancelAnimationFrame(frame);
      stopResettling();
    };
  }, [article.slug]);

  return (
    <HelpCenterLayout showSearchButton>
      <div className="flex max-w-7xl flex-col-reverse gap-8 md:flex-row md:gap-16">
        <CategorySidebar categories={sidebar_categories} activeSlug={article.category.slug} />
        <div className="flex-1 grow rounded-sm border border-[rgb(var(--parent-color)/var(--border-alpha))] bg-[rgb(var(--filled))] p-8">
          <h2 className="mb-6 text-3xl font-bold">{article.title}</h2>
          <div
            ref={contentRef}
            className="scoped-tailwind-preflight prose dark:prose-invert"
            dangerouslySetInnerHTML={{ __html: article.content }}
          />
        </div>
      </div>
    </HelpCenterLayout>
  );
}
