import { usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { NavigationButton } from "$app/components/Button";

import { HelpCenterLayout } from "./Layout";

type Article = {
  title: string;
  url: string;
};

type Category = {
  url: string;
  title: string;
  audience: string;
  articles: Article[];
};

type HelperSession = {
  email?: string | null;
  emailHash?: string | null;
  timestamp?: number | null;
};

type PageProps = {
  categories: Category[];
  helper_host: string | null;
  helper_session: HelperSession | null;
  recaptcha_site_key: string | null;
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
          <NavigationButton
            key={article.url}
            href={article.url}
            color="filled"
            className="box-border! flex! h-full! w-full! items-center! justify-center! p-12! text-center text-xl!"
          >
            {renderHighlightedText(article.title, searchTerm)}
          </NavigationButton>
        ))}
      </div>
    </div>
  );
};

export default function HelpCenterIndex() {
  const { categories, helper_host, helper_session, recaptcha_site_key } = cast<PageProps>(usePage().props);
  const [searchTerm, setSearchTerm] = React.useState("");

  const filteredCategories = searchTerm
    ? categories.map((category) => ({
        ...category,
        articles: category.articles.filter((article) => article.title.toLowerCase().includes(searchTerm.toLowerCase())),
      }))
    : categories;

  return (
    <HelpCenterLayout host={helper_host} session={helper_session} recaptchaSiteKey={recaptcha_site_key}>
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
