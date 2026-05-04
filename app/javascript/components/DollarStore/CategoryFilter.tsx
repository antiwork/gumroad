import { ChevronDown, ChevronLeft, ChevronRight } from "@boxicons/react";
import { router } from "@inertiajs/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { getRootTaxonomy, getRootTaxonomyImage } from "$app/utils/discover";

import merchandiseIcon from "$assets/images/discover/merchandise.svg";

export type Taxonomy = {
  key: string;
  label: string;
  slug: string;
  parent_key: string | null;
};

type Props = {
  taxonomies: Taxonomy[];
  selectedPath: string | null;
  selectedLabel: string | null;
};

export const CategoryFilter = ({ taxonomies, selectedPath, selectedLabel }: Props) => {
  const [isOpen, setIsOpen] = React.useState(false);
  const [drillKey, setDrillKey] = React.useState<string | null>(null);
  const wrapperRef = React.useRef<HTMLDivElement>(null);

  React.useEffect(() => {
    if (!isOpen) return;
    const handleClick = (event: MouseEvent) => {
      if (wrapperRef.current && !wrapperRef.current.contains(event.target as Node)) {
        setIsOpen(false);
        setDrillKey(null);
      }
    };
    const handleEsc = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setIsOpen(false);
        setDrillKey(null);
      }
    };
    document.addEventListener("mousedown", handleClick);
    document.addEventListener("keydown", handleEsc);
    return () => {
      document.removeEventListener("mousedown", handleClick);
      document.removeEventListener("keydown", handleEsc);
    };
  }, [isOpen]);

  const taxonomyByKey = React.useMemo(() => new Map(taxonomies.map((t) => [t.key, t])), [taxonomies]);
  const roots = React.useMemo(
    () => taxonomies.filter((t) => !t.parent_key).sort((a, b) => a.label.localeCompare(b.label)),
    [taxonomies],
  );
  const hasChildren = React.useCallback((key: string) => taxonomies.some((x) => x.parent_key === key), [taxonomies]);

  const buildPath = (taxonomy: Taxonomy): string => {
    const slugs: string[] = [];
    let node: Taxonomy | undefined = taxonomy;
    while (node) {
      slugs.unshift(node.slug);
      node = node.parent_key ? taxonomyByKey.get(node.parent_key) : undefined;
    }
    return slugs.join("/");
  };

  const navigate = (path: string | null) => {
    const data = path ? { taxonomy: path } : {};
    router.get(Routes.dollar_store_path(), data, { preserveScroll: true, preserveState: false });
    setIsOpen(false);
    setDrillKey(null);
  };

  const drillTaxonomy = drillKey ? taxonomyByKey.get(drillKey) : null;
  const subItems = React.useMemo(() => {
    if (!drillTaxonomy) return [];
    return taxonomies.filter((t) => t.parent_key === drillTaxonomy.key).sort((a, b) => a.label.localeCompare(b.label));
  }, [drillTaxonomy, taxonomies]);

  const triggerLabel = selectedLabel ?? "all";
  const drilledRootSlug = drillKey ? getRootTaxonomy(taxonomyByKey.get(drillKey)?.slug) : null;
  const selectedRootSlug = getRootTaxonomy(selectedPath ?? undefined);
  const cornerSlug = drilledRootSlug ?? selectedRootSlug;
  const cornerIconUrl = cornerSlug ? getRootTaxonomyImage(cornerSlug) : merchandiseIcon;

  return (
    <div className="hidden items-center justify-center gap-3 px-4 pt-2 pb-8 text-xl text-black lg:flex">
      <span>Showing</span>
      <div className="relative" ref={wrapperRef}>
        <button
          type="button"
          aria-haspopup="menu"
          aria-expanded={isOpen}
          onClick={() => setIsOpen((v) => !v)}
          className="inline-flex cursor-pointer items-center gap-2 rounded border-2 border-black bg-white px-3 py-1 text-xl text-black shadow-[2px_2px_0_0_rgba(0,0,0,1)] transition-all duration-200 ease-out hover:-translate-x-0.5 hover:-translate-y-0.5 hover:shadow-[4px_4px_0_0_rgba(0,0,0,1)] active:translate-x-0 active:translate-y-0 active:shadow-[2px_2px_0_0_rgba(0,0,0,1)]"
        >
          <span>{triggerLabel}</span>
          <ChevronDown className="size-5" />
        </button>

        {isOpen ? (
          <div
            role="menu"
            className="absolute top-[calc(100%+8px)] left-1/2 z-40 w-[720px] max-w-[calc(100vw-2rem)] -translate-x-1/2 overflow-hidden border-2 border-black bg-dark-gray text-gray shadow-[6px_6px_0_0_rgba(0,0,0,1)]"
          >
            {drillTaxonomy ? (
              <SubcategoryView
                root={drillTaxonomy}
                subItems={subItems}
                onBack={() => setDrillKey(null)}
                onSelect={(path) => navigate(path)}
                buildPath={buildPath}
                selectedPath={selectedPath}
              />
            ) : (
              <RootView
                roots={roots}
                onSelectAll={() => navigate(null)}
                onSelectRoot={(t) => {
                  if (hasChildren(t.key)) {
                    setDrillKey(t.key);
                  } else {
                    navigate(buildPath(t));
                  }
                }}
                isAllSelected={!selectedPath}
                selectedRootKey={selectedPath ? findRootKey(selectedPath, roots) : null}
                hasChildren={hasChildren}
              />
            )}
            <CornerIcon iconUrl={cornerIconUrl} />
          </div>
        ) : null}
      </div>
      <span>products</span>
    </div>
  );
};

const findRootKey = (path: string, roots: Taxonomy[]) => {
  const rootSlug = path.split("/")[0];
  return roots.find((r) => r.slug === rootSlug)?.key ?? null;
};

type RootViewProps = {
  roots: Taxonomy[];
  onSelectAll: () => void;
  onSelectRoot: (t: Taxonomy) => void;
  isAllSelected: boolean;
  selectedRootKey: string | null;
  hasChildren: (key: string) => boolean;
};

const RootView = ({ roots, onSelectAll, onSelectRoot, isAllSelected, selectedRootKey, hasChildren }: RootViewProps) => (
  <div className="relative z-10 grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4">
    <MenuOption label="All" onClick={onSelectAll} isSelected={isAllSelected} hasChildren={false} />
    {roots.map((t) => (
      <MenuOption
        key={t.key}
        label={t.label}
        onClick={() => onSelectRoot(t)}
        isSelected={selectedRootKey === t.key}
        hasChildren={hasChildren(t.key)}
      />
    ))}
  </div>
);

type SubcategoryViewProps = {
  root: Taxonomy;
  subItems: Taxonomy[];
  onBack: () => void;
  onSelect: (path: string) => void;
  buildPath: (t: Taxonomy) => string;
  selectedPath: string | null;
};

const SubcategoryView = ({ root, subItems, onBack, onSelect, buildPath, selectedPath }: SubcategoryViewProps) => {
  const rootPath = buildPath(root);
  const allRootSelected = selectedPath === rootPath;
  return (
    <div className="relative z-10 flex flex-col">
      <button
        type="button"
        onClick={onBack}
        className="relative z-10 flex cursor-pointer items-center gap-1 border-b-2 border-black bg-transparent px-4 py-3 text-left text-lg text-gray hover:bg-gray hover:text-dark-gray"
      >
        <ChevronLeft className="size-6" />
        <span>Back to all categories</span>
      </button>
      <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4">
        <MenuOption
          label={`All ${root.label}`}
          onClick={() => onSelect(rootPath)}
          isSelected={allRootSelected}
          hasChildren={false}
        />
        {subItems.map((t) => (
          <MenuOption
            key={t.key}
            label={t.label}
            onClick={() => onSelect(buildPath(t))}
            isSelected={selectedPath === buildPath(t)}
            hasChildren={false}
          />
        ))}
      </div>
    </div>
  );
};

const MenuOption = ({
  label,
  onClick,
  isSelected,
  hasChildren,
}: {
  label: string;
  onClick: () => void;
  isSelected: boolean;
  hasChildren: boolean;
}) => (
  <button
    type="button"
    role="menuitem"
    onClick={onClick}
    aria-current={isSelected ? "true" : undefined}
    className="relative z-10 flex cursor-pointer items-center justify-between gap-2 bg-transparent p-4 text-left text-lg text-gray hover:bg-gray hover:text-dark-gray"
  >
    <span className={classNames("min-w-0 break-words", !hasChildren && "underline")}>{label}</span>
    {hasChildren ? <ChevronRight className="size-5 shrink-0" /> : null}
  </button>
);

const CornerIcon = ({ iconUrl }: { iconUrl: string }) => (
  <img
    src={iconUrl}
    aria-hidden
    alt=""
    className="pointer-events-none absolute -right-10 -bottom-10 z-0 h-32 w-auto opacity-25"
  />
);
