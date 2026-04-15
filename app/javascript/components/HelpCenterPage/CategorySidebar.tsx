import { Link } from "@inertiajs/react";
import * as React from "react";

import { SidebarCategory } from "./types";

export function CategorySidebar({ categories, activeSlug }: { categories: SidebarCategory[]; activeSlug: string }) {
  return (
    <div className="md:pt-8 md:pr-8">
      <h3 className="mb-4 font-semibold">Categories</h3>
      <ul className="list-none space-y-4 pl-0!">
        {categories.map((category) => (
          <li key={category.slug}>
            <Link href={category.url} className={category.slug === activeSlug ? "font-bold" : ""}>
              {category.title}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
