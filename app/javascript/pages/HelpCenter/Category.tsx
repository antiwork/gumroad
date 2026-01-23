import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { HelpCenterLayout } from "./Layout";

type ArticleLink = {
  title: string;
  url: string;
};

type CategoryLink = {
  title: string;
  slug: string;
  url: string;
  isActive: boolean;
};

type HelperSession = {
  email?: string | null;
  emailHash?: string | null;
  timestamp?: number | null;
};

type PageProps = {
  category: {
    title: string;
    slug: string;
    articles: ArticleLink[];
  };
  categories: CategoryLink[];
  helper_host: string | null;
  helper_session: HelperSession | null;
  recaptcha_site_key: string | null;
};

function CategorySidebar({ categories }: { categories: CategoryLink[] }) {
  return (
    <div className="md:pt-8 md:pr-8">
      <h3 className="mb-4 font-semibold">Categories</h3>
      <ul className="list-none space-y-4 pl-0!">
        {categories.map((category) => (
          <li key={category.slug}>
            <a href={category.url} className={category.isActive ? "font-bold" : ""}>
              {category.title}
            </a>
          </li>
        ))}
      </ul>
    </div>
  );
}

export default function HelpCenterCategory() {
  const { category, categories, helper_host, helper_session, recaptcha_site_key } = cast<PageProps>(usePage().props);

  return (
    <HelpCenterLayout host={helper_host} session={helper_session} recaptchaSiteKey={recaptcha_site_key}>
      <div className="flex max-w-7xl flex-col-reverse gap-8 md:flex-row md:gap-16">
        <CategorySidebar categories={categories} />

        <div className="flex-1 grow rounded-sm border border-[rgb(var(--parent-color)/var(--border-alpha))] bg-[rgb(var(--filled))] p-8">
          <h2 className="mb-6 text-3xl font-bold">{category.title}</h2>
          <div className="scoped-tailwind-preflight prose dark:prose-invert">
            <div className="space-y-4">
              {category.articles.map((article) => (
                <div key={article.url} className="flex items-center space-x-3">
                  <a
                    href={article.url}
                    className="flex w-fit items-center gap-2 font-medium hover:text-blue-600 hover:underline"
                  >
                    <svg className="h-5 w-5 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path
                        strokeLinecap="round"
                        strokeLinejoin="round"
                        strokeWidth="2"
                        d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                      />
                    </svg>
                    {article.title}
                  </a>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </HelpCenterLayout>
  );
}
