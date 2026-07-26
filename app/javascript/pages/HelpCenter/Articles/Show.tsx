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
      // Carry the fragment through the Inertia visit. Articles deep-link into each other's
      // sections (for example the payout settings requirements point at "Address verification" in
      // "Getting paid"), and navigating to the pathname alone silently drops the "#section" part,
      // dumping the reader at the top of the destination article instead.
      router.get(`${resolvedUrl.pathname}${resolvedUrl.hash}`);
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
