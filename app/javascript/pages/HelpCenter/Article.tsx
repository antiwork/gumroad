import { Head, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { CategorySidebar } from "./components/CategorySidebar";
import { HelpCenterLayout } from "./Layout";
import type { Article, CategorySummary, Meta } from "./types";

type Props = {
  article: Article;
  sidebar_categories: CategorySummary[];
  meta: Meta;
};

export default function HelpCenterArticle() {
  const { article, sidebar_categories, meta } = cast<Props>(usePage().props);

  return (
    <HelpCenterLayout showSearchButton>
      <Head>
        <title>{meta.title}</title>
        <meta name="description" content={meta.description} />
        <link rel="canonical" href={meta.canonical_url} />
        <meta property="og:title" content={meta.title} />
        <meta property="og:description" content={meta.description} />
        <meta property="og:type" content="website" />
        <meta property="og:url" content={meta.canonical_url} />
        <meta name="twitter:card" content="summary" />
        <meta name="twitter:title" content={meta.title} />
        <meta name="twitter:description" content={meta.description} />
      </Head>
      <div className="flex max-w-7xl flex-col-reverse gap-8 md:flex-row md:gap-16">
        <CategorySidebar categories={sidebar_categories} />
        <div className="flex-1 grow rounded-sm border border-[rgb(var(--parent-color)/var(--border-alpha))] bg-[rgb(var(--filled))] p-8">
          <h2 className="mb-6 text-3xl font-bold">{article.title}</h2>
          <div
            className="scoped-tailwind-preflight prose dark:prose-invert"
            dangerouslySetInnerHTML={{ __html: article.content }}
          />
        </div>
      </div>
    </HelpCenterLayout>
  );
}
