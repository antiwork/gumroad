import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { HelpCenterLayout } from "./Layout";

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
  article: {
    title: string;
    slug: string;
    content_html: string;
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

export default function HelpCenterArticle() {
  const { article, categories, helper_host, helper_session, recaptcha_site_key } = cast<PageProps>(usePage().props);

  return (
    <HelpCenterLayout host={helper_host} session={helper_session} recaptchaSiteKey={recaptcha_site_key}>
      <div className="flex max-w-7xl flex-col-reverse gap-8 md:flex-row md:gap-16">
        <CategorySidebar categories={categories} />

        <div className="flex-1 grow rounded-sm border border-[rgb(var(--parent-color)/var(--border-alpha))] bg-[rgb(var(--filled))] p-8">
          <h2 className="mb-6 text-3xl font-bold">{article.title}</h2>
          <div
            className="scoped-tailwind-preflight prose dark:prose-invert"
            dangerouslySetInnerHTML={{ __html: article.content_html }}
          />
        </div>
      </div>
    </HelpCenterLayout>
  );
}
