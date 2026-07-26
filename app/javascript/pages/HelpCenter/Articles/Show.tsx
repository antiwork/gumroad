import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { CategorySidebar } from "$app/components/HelpCenterPage/CategorySidebar";
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

// Firefox and Safari do not implement text directives at all, so nothing strips them and the
// fragment is still readable after a plain page load. Read whichever source has it.
const takePendingTextDirective = (fragment: string): string | null => {
  const pending = textDirectivePendingScroll;
  textDirectivePendingScroll = null;
  if (pending?.path === window.location.pathname) return pending.passage;
  return textDirectiveTerm(fragment);
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
      textDirectivePendingScroll = passage === null ? null : { path: resolvedUrl.pathname, passage };
      // Carry the fragment through the Inertia visit. Articles deep-link into each other's
      // sections (for example the payout settings requirements point at "Address verification" in
      // "Getting paid"), and navigating to the pathname alone silently drops the "#section" part,
      // dumping the reader at the top of the destination article instead.
      const url = `${resolvedUrl.pathname}${resolvedUrl.hash}`;
      if (passage === null) {
        router.get(url);
      } else {
        // A cancelled or failed visit never renders the article that would consume the remembered
        // wording, so forget it here instead of leaving it behind for a later visit to that same
        // article to act on.
        const forget = () => {
          textDirectivePendingScroll = null;
        };
        router.get(url, {}, { onCancel: forget, onError: forget });
      }
    };

    container.addEventListener("click", onLinkClick);
    return () => container.removeEventListener("click", onLinkClick);
  }, []);

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
    if (passage !== null) {
      const container = contentRef.current;
      if (container) elementContainingText(container, passage)?.scrollIntoView();
      return;
    }

    // Nothing to scroll to. Note that on a direct page load of a text-directive URL in a browser
    // that hides the directive, this is where we end up and there is nothing we can do: the
    // wording is unrecoverable from script, so the browser's own text-fragment scrolling is the
    // only thing that can act on it.
    if (!fragment) return;

    let id = fragment;
    try {
      id = decodeURIComponent(fragment);
    } catch {
      // A malformed escape sequence means the fragment isn't encoded — use it as-is.
    }

    document.getElementById(id)?.scrollIntoView();
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
