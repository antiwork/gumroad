import { Head, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { NavigationButtonInertia } from "$app/components/NavigationButton";

import { HelpCenterLayout } from "./Layout";
import type { Meta } from "./types";

type ArticleSummary = {
  title: string;
  url: string;
};

type Category = {
  title: string;
  slug: string;
  url: string;
  audience: string;
  articles: ArticleSummary[];
};

type Props = {
  categories: Category[];
  meta: Meta;
};

const escapeRegExp = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");

const renderHighlightedText = (text: string, searchTerm: string): React.ReactNode => {
  if (!searchTerm) return text;

  const escaped = escapeRegExp(searchTerm);
  const regex = new RegExp(`(${escaped})`, "giu");

  return (
    <span
      dangerouslySetInnerHTML={{
        __html: text.replace(regex, (match) => `<mark class="highlight rounded-xs bg-pink">${match}</mark>`),
      }}
    />
  );
};

const CategoryArticles = ({ category, searchTerm }: { category: Category; searchTerm: string }) => {
  if (category.articles.length === 0) return null;

  return (
    <div className="w-full">
      <h2 className="mb-4 font-semibold">{category.title}</h2>
      <div
        className="w-full grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4"
        style={{ display: "grid", gridAutoRows: "160px" }}
      >
        {category.articles.map((article) => (
          <NavigationButtonInertia
            key={article.url}
            href={article.url}
            color="filled"
            className="box-border! flex! h-full! w-full! items-center! justify-center! p-12! text-center text-xl!"
          >
            {renderHighlightedText(article.title, searchTerm)}
          </NavigationButtonInertia>
        ))}
      </div>
    </div>
  );
};

export default function HelpCenterIndex() {
  const { categories, meta } = cast<Props>(usePage().props);
  const [searchTerm, setSearchTerm] = React.useState("");

  const filteredCategories = searchTerm
    ? categories.map((category) => ({
        ...category,
        articles: category.articles.filter((article) => article.title.toLowerCase().includes(searchTerm.toLowerCase())),
      }))
    : categories;

  return (
    <HelpCenterLayout>
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
      <input
        type="text"
        autoFocus
        value={searchTerm}
        onChange={(e) => setSearchTerm(e.target.value)}
        placeholder="Search articles..."
        className="w-full"
      />
      <div className="mt-12 space-y-12">
        {filteredCategories.map((category) => (
          <CategoryArticles key={category.url} category={category} searchTerm={searchTerm} />
        ))}
      </div>
    </HelpCenterLayout>
  );
}
