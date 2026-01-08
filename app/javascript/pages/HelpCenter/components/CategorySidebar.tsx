import { Link } from "@inertiajs/react";
import React from "react";

import type { CategorySummary } from "../types";

export function CategorySidebar({ categories }: { categories: CategorySummary[] }) {
  return (
    <div className="md:pt-8 md:pr-8">
      <h3 className="mb-4 font-semibold">Categories</h3>
      <ul className="list-none space-y-4 pl-0!">
        {categories.map((cat) => (
          <li key={cat.slug}>
            <Link href={cat.url} className={cat.is_active ? "font-bold" : ""}>
              {cat.title}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
