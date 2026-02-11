import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

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
  const { article, sidebar_categories } = cast<Props>(usePage().props);
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

      const isSamePath = resolvedUrl.pathname === usePage().url;
      const hasAnchor = resolvedUrl.hash.length > 0;
      if (isSamePath && hasAnchor) return;

      if (resolvedUrl.origin === window.location.origin && resolvedUrl.pathname.startsWith("/help/")) {
        e.preventDefault();
        router.get(resolvedUrl.pathname);
      }
    };

    container.addEventListener("click", onLinkClick);
    return () => container.removeEventListener("click", onLinkClick);
  }, []);

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
