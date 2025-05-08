import cx from "classnames";
import * as React from "react";

import { getRootTaxonomy, getRootTaxonomyCss, Taxonomy } from "$app/utils/discover";

import { NavigationButton } from "$app/components/Button";
import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Nav } from "$app/components/Discover/Nav";
import { Search } from "$app/components/Discover/Search";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

import logo from "$assets/images/logo.svg";
interface UserActionsButtonsProps {
  currentSeller: ReturnType<typeof useCurrentSeller>;
}

const UserActionsButtons: React.FC<UserActionsButtonsProps> = ({ currentSeller }) => (
  <>
    {currentSeller ? (
      <NavigationButton href={Routes.library_url()}>
        <Icon name="bookmark-heart-fill" /> Library
      </NavigationButton>
    ) : (
      <NavigationButton href={Routes.login_url()}>Log in</NavigationButton>
    )}
    <CartNavigationButton className="link-button" />
    {!currentSeller?.has_published_products && (
      <NavigationButton href={Routes.root_url()} color="primary">
        Start Selling
      </NavigationButton>
    )}
  </>
);

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
  const { discoverDomain, appDomain } = useDomains();
  const isDesktop = useIsAboveBreakpoint("lg");
  const currentSeller = useCurrentSeller();

  const rootTaxonomy = getRootTaxonomy(taxonomyPath);

  setQuery ??= (query) => (window.location.href = Routes.discover_url({ host: discoverDomain, query }));

  onTaxonomyChange ??= (newTaxonomyPath) => {
    window.location.href = forceDomain
      ? newTaxonomyPath || Routes.discover_path()
      : Routes.discover_url({ host: discoverDomain, taxonomy: newTaxonomyPath });
  };

  const headerLinks = <UserActionsButtons currentSeller={currentSeller} />;

  const avatar = currentSeller ? (
    <a href={Routes.dashboard_url({ host: appDomain })} aria-label="Dashboard">
      <img className="user-avatar" src={currentSeller.avatarUrl} />
    </a>
  ) : null;

  const nav = (
    <Nav
      wholeTaxonomy={taxonomiesForNav}
      currentTaxonomyPath={taxonomyPath}
      onClickTaxonomy={onTaxonomyChange}
      forceDomain={forceDomain}
      footer={
        <footer>
          <UserActionsButtons currentSeller={currentSeller} />
        </footer>
      }
    />
  );

  return (
    <main className={cx("discover", className)}>
      <header
        className="hero border-t-0 lg:pe-16 lg:ps-16"
        style={showTaxonomy && rootTaxonomy ? getRootTaxonomyCss(rootTaxonomy) : undefined}
      >
        <div className="hero-actions">
          <a href={Routes.discover_path()} className="flex items-center">
            <img src={logo} alt="Gumroad" className="h-8 dark:invert" />
          </a>
          <Search query={query} setQuery={setQuery} />

          {isDesktop ? headerLinks : null}

          <div className="separator" />

          <div className="flex w-full items-center justify-between lg:order-2">
            <div className="flex-auto">{nav}</div>
            {avatar}
          </div>
        </div>
        {showTaxonomy && taxonomyPath ? (
          <div className="col-start-1 flex items-center">
            <div>
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
