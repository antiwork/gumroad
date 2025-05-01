import cx from "classnames";
import * as React from "react";

import { getRootTaxonomy, getRootTaxonomyCss, Taxonomy } from "$app/utils/discover";

import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Nav } from "$app/components/Discover/Nav";
import { Search } from "$app/components/Discover/Search";
import { useDomains } from "$app/components/DomainSettings";
import { Nav as HomeNav } from "$app/components/Home/Nav";
import { Icon } from "$app/components/Icons";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

export const Layout: React.FC<{
  taxonomiesForNav: Taxonomy[];
  taxonomyPath?: string | undefined;
  showTaxonomy?: boolean;
  onTaxonomyChange?: (newTaxonomyPath?: string) => void;
  query?: string | undefined;
  setQuery?: (query: string) => void;
  className?: string;
  children: React.ReactNode;
  forceDomain?: boolean;
}> = ({
  taxonomiesForNav,
  taxonomyPath,
  showTaxonomy,
  onTaxonomyChange,
  query,
  setQuery,
  className,
  children,
  forceDomain = false,
}) => {
  const { discoverDomain } = useDomains();
  const isDesktop = useIsAboveBreakpoint("lg");
  const currentSeller = useCurrentSeller();

  const rootTaxonomy = getRootTaxonomy(taxonomyPath);

  setQuery ??= (query) => (window.location.href = Routes.discover_url({ host: discoverDomain, query }));

  onTaxonomyChange ??= (newTaxonomyPath) => {
    window.location.href = forceDomain
      ? newTaxonomyPath || Routes.discover_path()
      : Routes.discover_url({ host: discoverDomain, taxonomy: newTaxonomyPath });
  };

  const headerCta = currentSeller && (
    <a href={Routes.library_url()} className="button">
      <Icon name="bookmark-heart-fill" /> Library
    </a>
  );

  const avatar = currentSeller ? (
    <a href={Routes.settings_main_url()} aria-label="Settings">
      <img className="user-avatar" src={currentSeller.avatarUrl} />
    </a>
  ) : null;

  const nav = (
    <Nav
      wholeTaxonomy={taxonomiesForNav}
      currentTaxonomyPath={taxonomyPath}
      onClickTaxonomy={onTaxonomyChange}
      forceDomain={forceDomain}
      footer={<footer>{headerCta}</footer>}
    />
  );

  return (
    <main className={cx("discover", className)}>
      <section className="content sticky top-0 z-50 p-0">
        <HomeNav />
      </section>
      <header
        className="hero border-t-0 lg:pe-16 lg:ps-16"
        style={showTaxonomy && rootTaxonomy ? getRootTaxonomyCss(rootTaxonomy) : undefined}
      >
        <div className="hero-actions">
          <CartNavigationButton className="link-button" />
          {isDesktop ? null : avatar}
          <div className="separator" />
          <Search query={query} setQuery={setQuery} />
          {isDesktop ? headerCta : nav}
          {isDesktop ? (
            <div className="order-1 flex flex-grow items-center justify-between">
              {nav}
              {avatar}
            </div>
          ) : null}
        </div>
        {showTaxonomy && taxonomyPath ? (
          <div className="col-start-1 grid">
            <div className="col-start-1">
              <TaxonomyCategoryBreadcrumbs
                taxonomyPath={taxonomyPath}
                taxonomies={taxonomiesForNav}
                onClickTaxonomy={onTaxonomyChange}
              />
            </div>
          </div>
        ) : null}
      </header>
      {children}
    </main>
  );
};

const TaxonomyCategoryBreadcrumbs = ({
  taxonomyPath,
  taxonomies,
  onClickTaxonomy,
}: {
  taxonomyPath: string;
  taxonomies: Taxonomy[];
  onClickTaxonomy: (taxonomySlugPath?: string) => void;
}) => (
  <div role="navigation" className="breadcrumbs" aria-label="Breadcrumbs">
    <ol itemScope itemType="https://schema.org/BreadcrumbList">
      {taxonomyPath.split("/").map((slug, index, breadcrumbs) => {
        const taxonomySlugPath = breadcrumbs.slice(0, index + 1).join("/");
        const label = taxonomies.find((t) => t.slug === slug)?.label ?? slug;
        return (
          <li key={taxonomySlugPath} itemProp="itemListElement" itemScope itemType="https://schema.org/ListItem">
            <a
              href={`/${taxonomySlugPath}`}
              onClick={(e) => {
                if (e.ctrlKey || e.shiftKey) return;
                e.preventDefault();
                onClickTaxonomy(taxonomySlugPath);
              }}
              aria-current={index === breadcrumbs.length - 1 ? "page" : undefined}
              itemProp="item"
            >
              <span itemProp="name">{label}</span>
            </a>
            <meta itemProp="position" content={(index + 1).toString()} />
          </li>
        );
      })}
    </ol>
  </div>
);
