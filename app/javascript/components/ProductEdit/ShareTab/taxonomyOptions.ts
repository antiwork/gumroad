import { Taxonomy } from "$app/utils/discover";

export type CategoryOption = { id: string; label: string };

// Build the category-picker options. Each taxonomy is labeled with its full breadcrumb
// ("Parent > Child") and the list is sorted alphabetically by that breadcrumb, so it reads
// as a predictable tree with each root immediately followed by its descendants.
//
// The `taxonomies` come from `Discover::TaxonomyPresenter#taxonomies_for_nav`, which is sorted
// by sales popularity for the Discover navigation. That order is right for the nav but wrong
// for a picker, where a seller is looking up a category they already have in mind.
export const buildCategoryOptions = (taxonomies: Taxonomy[]): CategoryOption[] => {
  const taxonomyMap = new Map(taxonomies.map((item) => [item.key, item]));
  return taxonomies
    .map((taxonomy) => {
      let label = taxonomy.label;
      let current: Taxonomy | undefined = taxonomy;
      while ((current = taxonomyMap.get(current.parent_key ?? ""))) label = `${current.label} > ${label}`;
      return { id: taxonomy.key, label };
    })
    .sort((a, b) => a.label.localeCompare(b.label));
};
