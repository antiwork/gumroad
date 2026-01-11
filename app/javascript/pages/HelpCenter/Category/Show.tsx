import { Head, Link, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { CategorySidebar } from "../components/CategorySidebar";
import { HelpCenterLayout } from "../Layout";
import type { CategorySummary, Meta } from "../types";

type CategoryWithArticles = {
  title: string;
  slug: string;
  articles: { title: string; url: string }[];
};

type HelpCenterCategoryProps = {
  category: CategoryWithArticles;
  sidebar_categories: CategorySummary[];
  meta: Meta;
};

export default function HelpCenterCategory() {
  const { category, sidebar_categories, meta } = cast<HelpCenterCategoryProps>(usePage().props);

  return (
    <HelpCenterLayout showSearchButton>
      <Head>
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
          <h2 className="mb-6 text-3xl font-bold">{category.title}</h2>
          <div className="space-y-4">
            {category.articles.map((article) => (
              <div key={article.url} className="flex items-center space-x-3">
                <Link
                  href={article.url}
                  className="flex w-fit items-center gap-2 font-medium hover:text-blue-600 hover:underline"
                >
                  <svg className="h-5 w-5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      strokeWidth="2"
                      d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                    ></path>
                  </svg>
                  {article.title}
                </Link>
              </div>
            ))}
          </div>
        </div>
      </div>
    </HelpCenterLayout>
  );
}
