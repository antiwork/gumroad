import { Head, usePage } from "@inertiajs/react";
import React, { Suspense, useEffect, useState } from "react";
import { cast } from "ts-safe-cast";

import { articleModules, type ArticleModule } from "../articles";
import { CategorySidebar } from "../components/CategorySidebar";
import { HelpCenterLayout } from "../Layout";
import type { CategorySummary, Meta } from "../types";

type Article = {
  title: string;
  slug: string;
  category: {
    title: string;
    slug: string;
    url: string;
  };
};

type Props = {
  article: Article;
  sidebar_categories: CategorySummary[];
  meta: Meta;
};

export default function HelpCenterArticle() {
  const { article, sidebar_categories, meta } = cast<Props>(usePage().props);
  const [ArticleContent, setArticleContent] = useState<React.ComponentType | null>(null);
  const [articleMeta, setArticleMeta] = useState<{ description: string } | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  useEffect(() => {
    const loader = articleModules[article.slug];
    if (loader) {
      setLoading(true);
      setError(false);
      loader()
        .then((module: ArticleModule) => {
          setArticleContent(() => module.default);
          setArticleMeta(module.meta);
          setLoading(false);
        })
        .catch(() => {
          setError(true);
          setLoading(false);
        });
    } else {
      setError(true);
      setLoading(false);
    }
  }, [article.slug]);

  const description = articleMeta?.description || meta.description;

  return (
    <HelpCenterLayout showSearchButton>
      <Head>
        <meta name="description" content={description} />
        <link rel="canonical" href={meta.canonical_url} />
        <meta property="og:title" content={meta.title} />
        <meta property="og:description" content={description} />
        <meta property="og:type" content="website" />
        <meta property="og:url" content={meta.canonical_url} />
        <meta name="twitter:card" content="summary" />
        <meta name="twitter:title" content={meta.title} />
        <meta name="twitter:description" content={description} />
      </Head>
      <div className="flex max-w-7xl flex-col-reverse gap-8 md:flex-row md:gap-16">
        <CategorySidebar categories={sidebar_categories} />
        <div className="flex-1 grow rounded-sm border border-[rgb(var(--parent-color)/var(--border-alpha))] bg-[rgb(var(--filled))] p-8">
          <h2 className="mb-6 text-3xl font-bold">{article.title}</h2>
          <div className="prose dark:prose-invert">
            {loading ? (
              <div className="flex items-center justify-center py-8">
                <p className="text-gray-500">Loading article...</p>
              </div>
            ) : null}
            {error ? (
              <div className="rounded-md bg-red-50 p-4">
                <p className="text-red-800">Failed to load article content. Please try refreshing the page.</p>
              </div>
            ) : null}
            {!loading && !error && ArticleContent ? (
              <Suspense fallback={<div>Loading...</div>}>
                <ArticleContent />
              </Suspense>
            ) : null}
          </div>
        </div>
      </div>
    </HelpCenterLayout>
  );
}
