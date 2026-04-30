import { CheckCircle, Circle } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Product, PublishReadiness, PublishReadinessItem, useProductEditContext } from "./state";

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

const ReadinessSection = ({ title, items }: { title: string; items: PublishReadinessItem[] }) =>
  items.length > 0 ? (
    <div className="grid gap-2">
      <h4 className="text-sm">{title}</h4>
      <ul className="grid gap-2">
        {items.map((item) => (
          <ReadinessListItem key={item.id} item={item} />
        ))}
      </ul>
    </div>
  ) : null;

const ReadinessListItem = ({ item }: { item: PublishReadinessItem }) => {
  const StatusIcon = item.complete ? CheckCircle : Circle;

  return (
    <li className={classNames("flex gap-2 text-sm", item.complete && "text-muted")}>
      <StatusIcon
        {...(item.complete ? { pack: "filled" as const } : {})}
        className={classNames(
          "mt-0.5 size-5 flex-none",
          item.complete ? "text-success" : item.severity === "required" ? "text-warning" : "text-muted",
        )}
      />
      <span>
        {item.label}
        {item.description ? <small className="block text-muted">{item.description}</small> : null}
      </span>
    </li>
  );
};

export const PublishReadinessPanel = () => {
  const { product, publishReadiness: initialPublishReadiness, thumbnail } = useProductEditContext();
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

  return (
    <section
      className="grid gap-3 rounded border border-border bg-background p-4"
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
      </div>
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
      <ReadinessSection title="Fix before sharing" items={incompleteRequiredItems} />
      <ReadinessSection title="Nice to have" items={incompleteRecommendedItems} />
      <ReadinessSection title="Already set" items={completedItems} />
    </section>
  );
};
