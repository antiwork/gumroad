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

const UserActionButtons: React.FC = () => {
  const currentSeller = useCurrentSeller();

  if (currentSeller) {
    return (
      <>
        <NavigationButton href={Routes.library_url()} className="flex-1 lg:flex-none">
          <Icon name="bookmark-heart-fill" /> Library
        </NavigationButton>
        {currentSeller.has_published_products ? null : (
          <NavigationButton href={Routes.products_url()} color="primary" className="flex-1 lg:flex-none">
            Start selling
          </NavigationButton>
        )}
      </>
    );
  }

  return (
    <>
      <NavigationButton href={Routes.login_url()} className="flex-1 lg:flex-none">
        Log in
      </NavigationButton>
      <NavigationButton href={Routes.signup_url()} color="primary" className="flex-1 lg:flex-none">
        Start selling
      </NavigationButton>
    </>
  );
};

interface HeaderRowElementsProps {
  logoLink: React.ReactNode;
  searchBar: React.ReactNode;
  userActionButtons: React.ReactNode;
  cartButton: React.ReactNode;
  avatarElement: React.ReactNode;
  navElementNoFooter: React.ReactNode;
  navElementWithFooter: React.ReactNode;
}

const DesktopHeaderRows: React.FC<HeaderRowElementsProps> = ({
  logoLink,
  searchBar,
  userActionButtons,
  cartButton,
  avatarElement,
  navElementNoFooter,
}) => (
  <>
    <div className="flex w-full items-center gap-4">
      {logoLink}
      {searchBar}
      <div className="flex flex-shrink-0 items-center space-x-4">
        {userActionButtons}
        {cartButton}
      </div>
    </div>
    <div className="flex w-full items-center justify-between gap-4">
      <div className="flex-grow">{navElementNoFooter}</div>
      {avatarElement}
    </div>
  </>
);

const MobileHeaderRows: React.FC<HeaderRowElementsProps> = ({
  logoLink,
  searchBar,
  cartButton,
  avatarElement,
  navElementWithFooter,
}) => (
  <>
    <div className="flex w-full items-center justify-between">
      {logoLink}
      <div className="flex items-center gap-4">
        {avatarElement}
        {cartButton}
      </div>
    </div>
    <div className="flex w-full items-center gap-4">
      {searchBar}
      {navElementWithFooter}
    </div>
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

  const userActionButtons = <UserActionButtons />;

  const logoLink = (
    <a
      href={Routes.discover_url({ host: discoverDomain })}
      className="logo-full flex aspect-[157/22] !w-[245px] flex-shrink-0 items-center"
      aria-label="Gumroad"
    />
  );
  const searchBar = (
    <div className="min-w-0 flex-grow">
      <Search query={query} setQuery={setQuery} />
    </div>
  );
  const cartButton = <CartNavigationButton className="link-button flex-shrink-0" />;
  const avatarElement = currentSeller ? (
    <a href={Routes.dashboard_url({ host: appDomain })} aria-label="Dashboard" className="flex-shrink-0">
      <img className="user-avatar" src={currentSeller.avatarUrl} />
    </a>
  ) : null;

  const navElementWithFooter = (
    <Nav
      wholeTaxonomy={taxonomiesForNav}
      currentTaxonomyPath={taxonomyPath}
      onClickTaxonomy={onTaxonomyChange}
      forceDomain={forceDomain}
      footer={<div className="flex gap-4 border-b p-4 pb-4">{userActionButtons}</div>}
    />
  );

  const navElementNoFooter = (
    <Nav
      wholeTaxonomy={taxonomiesForNav}
      currentTaxonomyPath={taxonomyPath}
      onClickTaxonomy={onTaxonomyChange}
      forceDomain={forceDomain}
      footer={undefined}
    />
  );

  const headerRowElementsProps: HeaderRowElementsProps = {
    logoLink,
    searchBar,
    userActionButtons,
    cartButton,
    avatarElement,
    navElementNoFooter,
    navElementWithFooter,
  };

  return (
    <div className={cx("discover", className)}>
      <header
        className="hero relative z-20 border-b border-t-0 border-border bg-body px-4 py-8 lg:pe-16 lg:ps-16"
        style={showTaxonomy && rootTaxonomy ? getRootTaxonomyCss(rootTaxonomy) : undefined}
      >
        <div className="flex w-full flex-col gap-4">
          {isDesktop ? (
            <DesktopHeaderRows {...headerRowElementsProps} />
          ) : (
            <MobileHeaderRows {...headerRowElementsProps} />
          )}
        </div>

        {showTaxonomy && taxonomyPath ? (
          <TaxonomyCategoryBreadcrumbs
            taxonomyPath={taxonomyPath}
            taxonomies={taxonomiesForNav}
            onClickTaxonomy={onTaxonomyChange}
          />
        ) : null}
      </header>
      {children}
    </div>
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
  <div role="navigation" className="breadcrumbs mt-4" aria-label="Breadcrumbs">
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
