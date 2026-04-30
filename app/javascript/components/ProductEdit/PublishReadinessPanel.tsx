import { CheckCircle, ChevronDown, ChevronRight, Circle } from "@boxicons/react";
import * as React from "react";
import { useLocation, useNavigate } from "react-router-dom";

import { classNames } from "$app/utils/classNames";

import { Product, PublishReadiness, PublishReadinessItem, useProductEditContext } from "./state";

const PANEL_EXPANDED_STORAGE_KEY = "product-edit-readiness-panel-expanded";

type ReadinessTarget = {
  tab: NonNullable<PublishReadinessItem["tab"]>;
  sectionId: string;
  label: string;
};

const PRODUCT_DETAILS_SECTION_ID = "product-edit-details";
const PRODUCT_COVER_SECTION_ID = "product-edit-cover";
const PRODUCT_PRICING_SECTION_ID = "product-edit-pricing";
const PRODUCT_TIERS_SECTION_ID = "product-edit-tiers";
const PRODUCT_CALL_DURATIONS_SECTION_ID = "product-edit-call-durations";
const PRODUCT_CALL_AVAILABILITY_SECTION_ID = "product-edit-call-availability";
const PRODUCT_SHIPPING_SECTION_ID = "product-edit-shipping";
const CONTENT_SECTION_ID = "product-edit-content";
const SHARE_DISCOVER_SECTION_ID = "product-edit-discover";

const getStoredExpanded = () => {
  try {
    const stored = sessionStorage.getItem(PANEL_EXPANDED_STORAGE_KEY);
    return stored == null ? null : stored === "true";
  } catch {
    return null;
  }
};

const setStoredExpanded = (expanded: boolean) => {
  try {
    sessionStorage.setItem(PANEL_EXPANDED_STORAGE_KEY, String(expanded));
  } catch {}
};

const textContentFromHtml = (html: string) => {
  if (typeof document === "undefined")
    return html
      .replace(/<[^>]*>/gu, "")
      .replace(/\u00a0/gu, " ")
      .trim();

  const element = document.createElement("div");
  element.innerHTML = html;
  return (element.textContent ?? "").replace(/\u00a0/gu, " ").trim();
};

const hasDescription = (product: Product) =>
  textContentFromHtml(product.description).length > 0 || !!product.custom_summary?.trim();

const hasPageContent = (pages: Product["rich_content"]) =>
  pages.some((page) => {
    const content = "content" in page.description ? page.description.content : null;
    return Array.isArray(content) && content.length > 0;
  });

const hasContent = (product: Product) => {
  const pages =
    product.has_same_rich_content_for_all_variants || product.variants.length === 0
      ? product.rich_content
      : product.variants.flatMap((variant) => variant.rich_content);

  return product.files.length > 0 || hasPageContent(pages);
};

const completeValue = (item: PublishReadinessItem, product: Product, thumbnailPresent: boolean): boolean | null => {
  switch (item.id) {
    case "name":
      return product.name.trim().length > 0;
    case "price":
      return product.price_cents != null || product.customizable_price;
    case "description":
      return hasDescription(product);
    case "content":
      return hasContent(product);
    case "shipping":
      return product.shipping_destinations.length > 0;
    case "call_schedule":
      return (
        product.variants.some((variant) => "duration_in_minutes" in variant && variant.duration_in_minutes != null) &&
        product.availabilities.length > 0
      );
    case "membership_tier":
      return product.variants.length > 0;
    case "cover":
      return product.covers.length > 0 || thumbnailPresent;
    case "discover_metadata":
      return !!product.taxonomy_id || product.tags.length > 0;
    default:
      return null;
  }
};

const readinessFromProduct = (
  readiness: PublishReadiness,
  product: Product,
  thumbnailPresent: boolean,
): PublishReadiness => {
  const items = readiness.items.map((item) => {
    const complete = completeValue(item, product, thumbnailPresent);
    return complete == null ? item : { ...item, complete };
  });

  return {
    ...readiness,
    complete_count: items.filter((item) => item.complete).length,
    required_complete: items.every((item) => item.severity !== "required" || item.complete),
    items,
  };
};

const getReadinessTarget = (item: PublishReadinessItem, product: Product): ReadinessTarget | null => {
  switch (item.id) {
    case "name":
    case "description":
      return { tab: "product", sectionId: PRODUCT_DETAILS_SECTION_ID, label: "Product" };
    case "price":
      return { tab: "product", sectionId: PRODUCT_PRICING_SECTION_ID, label: "Product" };
    case "content":
      return { tab: "content", sectionId: CONTENT_SECTION_ID, label: "Content" };
    case "shipping":
      return { tab: "product", sectionId: PRODUCT_SHIPPING_SECTION_ID, label: "Product" };
    case "call_schedule": {
      const hasDuration = product.variants.some(
        (variant) => "duration_in_minutes" in variant && variant.duration_in_minutes != null,
      );
      return {
        tab: "product",
        sectionId: hasDuration ? PRODUCT_CALL_AVAILABILITY_SECTION_ID : PRODUCT_CALL_DURATIONS_SECTION_ID,
        label: "Product",
      };
    }
    case "membership_tier":
      return { tab: "product", sectionId: PRODUCT_TIERS_SECTION_ID, label: "Product" };
    case "cover":
      return { tab: "product", sectionId: PRODUCT_COVER_SECTION_ID, label: "Product" };
    case "discover_metadata":
      return { tab: "share", sectionId: SHARE_DISCOVER_SECTION_ID, label: "Share -> Discover" };
    default:
      return item.tab ? { tab: item.tab, sectionId: PRODUCT_DETAILS_SECTION_ID, label: item.tab } : null;
  }
};

const scrollToSection = (sectionId: string, attempts = 20) => {
  const element = document.getElementById(sectionId);
  if (element) {
    element.scrollIntoView({ behavior: "smooth", block: "start" });
    return;
  }

  if (attempts > 0) window.setTimeout(() => scrollToSection(sectionId, attempts - 1), 50);
};

const ReadinessSection = ({
  title,
  items,
  onSelectItem,
  product,
}: {
  title: string;
  items: PublishReadinessItem[];
  onSelectItem: (item: PublishReadinessItem) => void;
  product: Product;
}) =>
  items.length > 0 ? (
    <div className="grid gap-2">
      <h4 className="text-sm">{title}</h4>
      <ul className="grid gap-2">
        {items.map((item) => (
          <ReadinessListItem
            key={item.id}
            item={item}
            target={getReadinessTarget(item, product)}
            onSelect={() => onSelectItem(item)}
          />
        ))}
      </ul>
    </div>
  ) : null;

const ReadinessListItem = ({
  item,
  target,
  onSelect,
}: {
  item: PublishReadinessItem;
  target: ReadinessTarget | null;
  onSelect: () => void;
}) => {
  const StatusIcon = item.complete ? CheckCircle : Circle;

  return (
    <li>
      <button
        type="button"
        className={classNames(
          "flex w-full cursor-pointer gap-2 rounded p-1 text-left text-sm all-unset hover:bg-active-bg",
          item.complete && "text-muted",
        )}
        onClick={onSelect}
      >
        <StatusIcon
          {...(item.complete ? { pack: "filled" as const } : {})}
          className={classNames(
            "mt-0.5 size-5 flex-none",
            item.complete ? "text-success" : item.severity === "required" ? "text-warning" : "text-muted",
          )}
        />
        <span>
          {item.label}
          {target ? <small className="ml-1 text-muted"> ({target.label})</small> : null}
          {item.description ? <small className="block text-muted">{item.description}</small> : null}
        </span>
      </button>
    </li>
  );
};

export const PublishReadinessPanel = () => {
  const { product, publishReadiness: initialPublishReadiness, thumbnail, uniquePermalink } = useProductEditContext();
  const navigate = useNavigate();
  const location = useLocation();
  const publishReadiness = React.useMemo(
    () => readinessFromProduct(initialPublishReadiness, product, thumbnail != null),
    [product, initialPublishReadiness, thumbnail],
  );
  const incompleteRequiredItems = publishReadiness.items.filter(
    (item) => item.severity === "required" && !item.complete,
  );
  const incompleteRecommendedItems = publishReadiness.items.filter(
    (item) => item.severity === "recommended" && !item.complete,
  );
  const completedItems = publishReadiness.items.filter((item) => item.complete);
  const allComplete = publishReadiness.complete_count === publishReadiness.total_count;
  const [userExpanded, setUserExpanded] = React.useState<boolean | null>(() => getStoredExpanded());
  const isExpanded = userExpanded ?? !allComplete;
  const progress =
    publishReadiness.total_count > 0
      ? Math.round((publishReadiness.complete_count / publishReadiness.total_count) * 100)
      : 0;
  const helperText =
    publishReadiness.complete_count === publishReadiness.total_count
      ? "Looks ready to share."
      : publishReadiness.required_complete
        ? "Looks ready to share. A few extras can still help."
        : "A few things will make this easier to buy.";
  const rootPath = Routes.edit_link_path(uniquePermalink);
  const pathForTab = (tab: NonNullable<PublishReadinessItem["tab"]>) =>
    tab === "product" ? rootPath : `${rootPath}/${tab}`;
  const onSelectItem = (item: PublishReadinessItem) => {
    const target = getReadinessTarget(item, product);
    if (!target) return;

    const path = pathForTab(target.tab);
    if (location.pathname !== path) navigate(path);
    window.requestAnimationFrame(() => scrollToSection(target.sectionId));
  };
  const toggleExpanded = () => {
    const expanded = !isExpanded;
    setUserExpanded(expanded);
    setStoredExpanded(expanded);
  };

  return (
    <section
      className={classNames("grid rounded border border-border bg-background p-4", isExpanded && "gap-3")}
      aria-labelledby="publish-readiness-title"
    >
      <div className="flex items-start justify-between gap-3">
        <div className="grid gap-1">
          <h3 id="publish-readiness-title" className="text-base">
            Ready to publish?
          </h3>
          <small className="text-muted">{helperText}</small>
        </div>
        <span className="shrink-0 rounded border border-border px-2 py-1 text-sm whitespace-nowrap">
          {publishReadiness.complete_count} of {publishReadiness.total_count} ready
        </span>
        <button
          type="button"
          className="cursor-pointer rounded p-1 all-unset hover:bg-active-bg"
          aria-expanded={isExpanded}
          aria-controls="publish-readiness-content"
          aria-label={isExpanded ? "Collapse publish readiness checklist" : "Expand publish readiness checklist"}
          onClick={toggleExpanded}
        >
          {isExpanded ? <ChevronDown className="size-5" /> : <ChevronRight className="size-5" />}
        </button>
      </div>
      {isExpanded ? (
        <div id="publish-readiness-content" className="grid gap-3">
          <div
            className="h-2 overflow-hidden rounded bg-active-bg"
            role="progressbar"
            aria-valuemin={0}
            aria-valuemax={publishReadiness.total_count}
            aria-valuenow={publishReadiness.complete_count}
            aria-label="Publish readiness"
          >
            <div className="h-full rounded bg-accent" style={{ width: `${progress}%` }} />
          </div>
          <ReadinessSection
            title="Fix before sharing"
            items={incompleteRequiredItems}
            product={product}
            onSelectItem={onSelectItem}
          />
          <ReadinessSection
            title="Nice to have"
            items={incompleteRecommendedItems}
            product={product}
            onSelectItem={onSelectItem}
          />
          <ReadinessSection title="Already set" items={completedItems} product={product} onSelectItem={onSelectItem} />
        </div>
      ) : null}
    </section>
  );
};
