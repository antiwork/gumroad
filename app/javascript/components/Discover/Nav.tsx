import * as React from "react";

import { getRootTaxonomy, getRootTaxonomyCss, getRootTaxonomyImage, Taxonomy } from "$app/utils/discover";

import { useDomains } from "$app/components/DomainSettings";
import { MenuItem, NestedMenu } from "$app/components/NestedMenu";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

const getPathname = (url: string) => {
  try {
    return new URL(url).pathname;
  } catch (_) {
    return url;
  }
};

export const Nav = ({
  wholeTaxonomy,
  currentTaxonomyPath,
  onClickTaxonomy,
  footer,
  forceDomain = false,
}: {
  wholeTaxonomy: Taxonomy[];
  currentTaxonomyPath?: string | undefined;
  onClickTaxonomy: (taxonomySlugPath?: string) => void;
  footer?: React.ReactNode;
  forceDomain?: boolean;
}) => {
  const { discoverDomain } = useDomains();
  const discoverUrl = Routes.discover_url({ host: discoverDomain });

  const menuItems = React.useMemo(
    () => generateTaxonomyItemsForMenu(wholeTaxonomy, forceDomain, discoverDomain),
    [wholeTaxonomy, discoverUrl],
  );

  const selectedCategory = menuItems.find((menuItem) => {
    if (!menuItem.href) return false;
    const pathname = getPathname(menuItem.href);
    return currentTaxonomyPath
      ? pathname === Routes.discover_taxonomy_path(currentTaxonomyPath)
      : pathname === Routes.discover_path();
  })?.key;

  const isDesktop = useIsAboveBreakpoint("lg");

  return (
    <div role="nav">
      <NestedMenu
        type={isDesktop ? "menubar" : "menu"}
        moreLabel="More Categories"
        buttonLabel="Categories"
        items={menuItems}
        selectedItemKey={selectedCategory}
        onSelectItem={(item) => {
          if (item.href) onClickTaxonomy(item.href.replace(/^\//u, ""));
        }}
        footer={footer}
        menuTop="80px"
      />
    </div>
  );
};

const generateTaxonomyItemsForMenu = (wholeTaxonomy: Taxonomy[], forceDomain: boolean, discoverDomain: string) => {
  const taxonomyMap = new Map(wholeTaxonomy.map((tc) => [tc.key, tc]));

  const generateHref = (taxonomyCategory: Taxonomy): string => {
    const slugs = [];
    let curr: Taxonomy | undefined = taxonomyCategory;
    while (curr) {
      slugs.unshift(curr.slug);
      curr = curr.parent_key ? taxonomyMap.get(curr.parent_key) : undefined;
    }

    return forceDomain
      ? Routes.discover_taxonomy_url(slugs.join("/"), { host: discoverDomain })
      : Routes.discover_taxonomy_path(slugs.join("/"));
  };

  return [
    {
      key: "all#key",
      label: "All",
      href: forceDomain ? Routes.discover_url({ host: discoverDomain }) : Routes.discover_path(),
    },
    ...wholeTaxonomy.map((taxonomy): MenuItem => {
      const root = getRootTaxonomy(taxonomy.slug);
      return {
        key: taxonomy.key,
        label: taxonomy.label,
        href: generateHref(taxonomy),
        ...(taxonomy.parent_key
          ? { parentKey: taxonomy.parent_key }
          : root
            ? { css: getRootTaxonomyCss(root), image: getRootTaxonomyImage(root) }
            : {}),
      };
    }),
  ];
};
