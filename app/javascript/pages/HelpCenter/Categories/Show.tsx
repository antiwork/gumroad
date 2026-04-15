import { Link, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CategorySidebar } from "$app/components/HelpCenterPage/CategorySidebar";
import { ArticleLink, SidebarCategory } from "$app/components/HelpCenterPage/types";

import { HelpCenterLayout } from "../Layout";

import articleIcon from "$assets/images/help-center/article-icon.svg";

interface Category {
  title: string;
  slug: string;
  articles: ArticleLink[];
}

interface Props {
  category: Category;
  sidebar_categories: SidebarCategory[];
}

export default function HelpCenterCategory() {
  const { category, sidebar_categories } = cast<Props>(usePage().props);

  return (
    <HelpCenterLayout showSearchButton>
      <div className="flex max-w-7xl flex-col-reverse gap-8 md:flex-row md:gap-16">
        <CategorySidebar categories={sidebar_categories} activeSlug={category.slug} />
        <div className="flex-1 grow rounded-sm border border-[rgb(var(--parent-color)/var(--border-alpha))] bg-[rgb(var(--filled))] p-8">
          <h2 className="mb-6 text-3xl font-bold">{category.title}</h2>
          <div className="space-y-4">
            {category.articles.map((article) => (
              <div key={article.url} className="flex items-center space-x-3">
                <Link
                  href={article.url}
                  className="flex w-fit items-center gap-2 font-medium hover:text-blue-600 hover:underline"
                >
                  <img src={articleIcon} alt="" className="h-5 w-5 shrink-0" />
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
