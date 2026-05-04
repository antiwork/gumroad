import { ArrowLeft, BookmarkHeart } from "@boxicons/react";
import { router } from "@inertiajs/react";
import * as React from "react";

import { NavigationButton } from "$app/components/Button";
import { CartNavigationButton } from "$app/components/Checkout/CartNavigationButton";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { Taxonomy } from "$app/components/DollarStore/CategoryFilter";
import { useDomains } from "$app/components/DomainSettings";
import { Logo } from "$app/components/Logo";
import { MenuItem, NestedMenu } from "$app/components/NestedMenu";
import { Avatar } from "$app/components/ui/Avatar";

import dollarBurst from "$assets/images/dollar-store/dollar-burst.png";
import storeItalic from "$assets/images/dollar-store/store-italic.png";

const ALL_KEY = "dollar-store-all";

const UserActionButtons = ({ stretch }: { stretch?: boolean }) => {
  const currentSeller = useCurrentSeller();
  const baseClass = stretch ? "w-full border border-black" : "flex-1 border border-black lg:flex-none";

  if (currentSeller) {
    return (
      <>
        <NavigationButton href={Routes.library_url()} className={baseClass}>
          <BookmarkHeart pack="filled" className="size-5" /> Library
        </NavigationButton>
        {currentSeller.has_published_products ? null : (
          <NavigationButton href={Routes.products_url()} color="primary" className={baseClass}>
            Start selling
          </NavigationButton>
        )}
      </>
    );
  }

  return (
    <>
      <NavigationButton href={Routes.login_url()} className={baseClass}>
        Log in
      </NavigationButton>
      <NavigationButton href={Routes.signup_url()} color="primary" className={baseClass}>
        Start selling
      </NavigationButton>
    </>
  );
};

type Props = {
  taxonomies: Taxonomy[];
  selectedPath: string | null;
};

export const DollarStoreHeader = ({ taxonomies, selectedPath }: Props) => {
  const { discoverDomain, appDomain } = useDomains();
  const currentSeller = useCurrentSeller();

  const taxonomyByKey = React.useMemo(() => new Map(taxonomies.map((t) => [t.key, t])), [taxonomies]);
  const buildPath = React.useCallback(
    (t: Taxonomy): string => {
      const slugs: string[] = [];
      let node: Taxonomy | undefined = t;
      while (node) {
        slugs.unshift(node.slug);
        node = node.parent_key ? taxonomyByKey.get(node.parent_key) : undefined;
      }
      return slugs.join("/");
    },
    [taxonomyByKey],
  );

  const menuItems = React.useMemo<MenuItem[]>(
    () => [
      { key: ALL_KEY, label: "All", href: Routes.dollar_store_path() },
      ...taxonomies.map((t) => ({
        key: t.key,
        label: t.label,
        href: `${Routes.dollar_store_path()}?taxonomy=${buildPath(t)}`,
        ...(t.parent_key ? { parentKey: t.parent_key } : {}),
      })),
    ],
    [taxonomies, buildPath],
  );

  const selectedKey = React.useMemo(() => {
    if (!selectedPath) return ALL_KEY;
    const segments = selectedPath.split("/");
    let parentKey: string | null = null;
    let match: Taxonomy | undefined;
    for (const slug of segments) {
      const next: Taxonomy | undefined = taxonomies.find((t) => t.slug === slug && t.parent_key === parentKey);
      if (!next) break;
      match = next;
      parentKey = next.key;
    }
    return match?.key ?? ALL_KEY;
  }, [selectedPath, taxonomies]);

  const handleSelect = (item: MenuItem) => {
    if (!item.href) return;
    const url = new URL(item.href, window.location.origin);
    const taxonomy = url.searchParams.get("taxonomy");
    const data = taxonomy ? { taxonomy } : {};
    router.get(Routes.dollar_store_path(), data, { preserveScroll: false, preserveState: false });
  };

  const drawerFooter = (
    <div className="flex flex-col gap-3 border-b border-black/15 p-4">
      <UserActionButtons stretch />
    </div>
  );

  return (
    <header className="bg-white px-4 py-8 lg:ps-16 lg:pe-16">
      <div className="flex flex-col items-center gap-6 lg:hidden">
        <div className="flex w-full items-center justify-between gap-4">
          <a href={Routes.discover_url({ host: discoverDomain })} aria-label="Gumroad" className="shrink-0 text-black">
            <Logo className="h-auto w-[200px]" />
          </a>
          <div className="flex items-center gap-3">
            <CartNavigationButton className="link-button shrink-0" />
            <NestedMenu
              type="menu"
              buttonLabel="Categories"
              items={menuItems}
              selectedItemKey={selectedKey}
              onSelectItem={handleSelect}
              footer={drawerFooter}
            />
          </div>
        </div>
        <div className="flex items-center gap-2">
          <img src={dollarBurst} alt="$1" className="h-20 w-auto" />
          <img src={storeItalic} alt="store" className="-ml-0.5 h-[26px] w-auto -translate-y-[3px]" />
        </div>
      </div>

      <div className="hidden w-full grid-cols-[1fr_auto_1fr] items-center gap-4 lg:grid">
        <div className="group relative w-fit shrink-0">
          <a href={Routes.discover_url({ host: discoverDomain })} aria-label="Gumroad" className="block text-black">
            <Logo className="h-auto w-[245px]" />
          </a>
          <span
            aria-hidden
            className="pointer-events-none absolute top-full left-0 mt-1 flex translate-x-3 items-center gap-1 text-sm whitespace-nowrap text-black opacity-0 transition-all duration-200 ease-out group-hover:translate-x-0 group-hover:opacity-100"
          >
            <ArrowLeft className="size-4" />
            Back to discover
          </span>
        </div>

        <div className="flex items-center gap-2">
          <img src={dollarBurst} alt="$1" className="h-24 w-auto" />
          <img src={storeItalic} alt="store" className="-ml-0.5 h-[34px] w-auto -translate-y-[3px]" />
        </div>

        <div className="flex shrink-0 items-center justify-end space-x-4">
          <UserActionButtons />
          <CartNavigationButton className="link-button shrink-0" />
          {currentSeller ? (
            <a href={Routes.dashboard_url({ host: appDomain })} aria-label="Dashboard" className="shrink-0">
              <Avatar src={currentSeller.avatarUrl} />
            </a>
          ) : null}
        </div>
      </div>
    </header>
  );
};
