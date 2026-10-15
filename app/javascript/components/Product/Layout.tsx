import { Pencil } from "@boxicons/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";
import { lazyWithRetry } from "$app/utils/lazy_chunk";

import { NavigationButton } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { FallbackOnError } from "$app/components/FallbackOnError";
import {
  Product,
  ProductDiscount,
  Purchase,
  RatingsSummary,
  useSelectionFromUrl,
  Props as ProductProps,
} from "$app/components/Product";
import {
  applySelection,
  buyerLocalPriceCentsForSelection,
  ConfigurationSelectorHandle,
  PriceSelection,
} from "$app/components/Product/ConfigurationSelector";
import { PriceTag } from "$app/components/Product/PriceTag";
import { getBundleComparisonPriceCents } from "$app/components/Product/pricing";
import { PurchaseButton } from "$app/components/Product/PurchaseButton";
import { needsOptionChoice } from "$app/components/Product/purchaseReadiness";
import type { PageProps as EditSectionsProps } from "$app/components/Profile/EditSections";
import { Section, PageProps as SectionsProps } from "$app/components/Profile/Sections";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";

export type Props = ProductProps & { main_section_index: number } & (SectionsProps | EditSectionsProps);

// Only the seller viewing their own page gets the section editor; LoggedInUserLayout holds the page
// until it arrives.
const LazySectionEditor = lazyWithRetry(
  () => import("$app/components/Product/SectionEditor"),
  (module) => module.SectionEditor,
);

export const Layout = (
  props: Props & {
    cart?: boolean;
    hasHero?: boolean;
    hideSellerByline?: boolean;
  },
) => {
  const {
    product,
    purchase,
    discount_code: discountCode,
    sale_label: saleLabel,
    cart,
    hasHero,
    wishlists,
    main_section_index,
  } = props;
  const [selection, setSelection] = useSelectionFromUrl(product);
  const ctaButtonRef = React.useRef<HTMLAnchorElement>(null);
  const ctaLabel = cart ? "Add to cart" : undefined;

  const configurationSelectorRef = React.useRef<ConfigurationSelectorHandle>(null);

  const productView = (
    <>
      <EditButton product={product} />
      <Product
        product={product}
        purchase={purchase}
        discountCode={discountCode ?? null}
        saleLabel={saleLabel ?? null}
        ctaLabel={ctaLabel}
        selection={selection}
        setSelection={setSelection}
        ctaButtonRef={ctaButtonRef}
        configurationSelectorRef={configurationSelectorRef}
        wishlists={wishlists}
        hideSellerByline={props.hideSellerByline}
      />
    </>
  );

  const mainSection = (
    <section className="border-b border-border">
      <div
        className={classNames(
          "mx-auto w-full max-w-product-page lg:py-16",
          props.sections.length > 0 ? "px-4 py-8" : "p-4 lg:px-8",
        )}
      >
        {productView}
      </div>
    </section>
  );

  return (
    <>
      <CtaBar
        product={product}
        purchase={purchase}
        discountCode={discountCode ?? null}
        ctaLabel={ctaLabel}
        selection={selection}
        setSelection={setSelection}
        ctaButtonRef={ctaButtonRef}
        configurationSelectorRef={configurationSelectorRef}
        hasHero={!!hasHero}
      />
      {"products" in props ? (
        <FallbackOnError fallback={mainSection}>
          <LazySectionEditor props={props} controls={false}>
            {productView}
          </LazySectionEditor>
        </FallbackOnError>
      ) : props.sections.length > 0 ? (
        props.sections.map((section, i) => (
          <React.Fragment key={section.id}>
            {i === main_section_index ? mainSection : null}
            <Section section={section} {...props} />
            {main_section_index >= props.sections.length && i === props.sections.length - 1 ? mainSection : null}
          </React.Fragment>
        ))
      ) : (
        mainSection
      )}
    </>
  );
};

const CtaBar = ({
  product,
  purchase,
  discountCode,
  ctaButtonRef,
  configurationSelectorRef,
  ctaLabel,
  selection,
  setSelection,
  hasHero,
}: {
  product: Product;
  purchase: Purchase | null;
  discountCode?: ProductDiscount | null;
  ctaButtonRef: React.RefObject<HTMLAnchorElement>;
  configurationSelectorRef: React.RefObject<ConfigurationSelectorHandle>;
  ctaLabel?: string | undefined;
  selection: PriceSelection;
  setSelection: React.Dispatch<React.SetStateAction<PriceSelection>>;
  hasHero: boolean;
}) => {
  const selectionAttributes = applySelection(product, discountCode?.valid ? discountCode.discount : null, selection);
  let { priceCents } = selectionAttributes;
  const { discountedPriceCents, isPWYW, selectedOption } = selectionAttributes;

  const [visible, setVisible] = React.useState(false);
  const ref = React.useRef<null | HTMLDivElement>(null);
  const isDesktop = useIsAboveBreakpoint("lg");

  React.useEffect(() => {
    if (!ctaButtonRef.current) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (!entry) return;

        setVisible(!entry.isIntersecting);
      },
      { threshold: 0.5 },
    );
    observer.observe(ctaButtonRef.current);
    return () => observer.disconnect();
  }, [ctaButtonRef]);

  const [height, setHeight] = React.useState(0);
  React.useEffect(() => {
    const element = ref.current;
    if (!element) return;
    const updateHeight = () => setHeight(element.getBoundingClientRect().height);
    updateHeight();
    const observer = new ResizeObserver(updateHeight);
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  // On mobile the bar is fixed to the bottom of the viewport, so the page has to reserve its height
  // at the end of the document or the footer's links sit underneath it. Desktop has the bar at the
  // top, so nothing is reserved there. The footer consumes this variable.
  React.useEffect(() => {
    const { style } = document.documentElement;
    style.setProperty("--product-cta-bar-height", visible && !isDesktop ? `${height}px` : "0px");
    return () => {
      style.removeProperty("--product-cta-bar-height");
    };
  }, [isDesktop, visible, height]);

  // Paid bundle tiers have no standalone price comparison.
  const bundleComparisonPriceCents = getBundleComparisonPriceCents(product, selectedOption);
  if (bundleComparisonPriceCents !== null) priceCents = bundleComparisonPriceCents;

  return (
    <section
      aria-label="Product information bar"
      className="border-0 bg-background"
      style={{
        overflow: "hidden",
        padding: 0,
        height: visible ? height : 0,
        transition: "var(--transition-duration)",
        flexShrink: 0,
        order: isDesktop ? undefined : 1,
        boxShadow: visible
          ? "0 var(--border-width) rgb(var(--color)), 0 calc(-1 * var(--border-width)) rgb(var(--color))"
          : undefined,
        position: "fixed",
        top: isDesktop ? 0 : undefined,
        bottom: isDesktop ? undefined : 0,
        left: 0,
        right: 0,
        zIndex: "var(--z-index-menubar)",
        marginTop: hasHero ? "var(--border-width)" : undefined,
      }}
    >
      <div
        ref={ref}
        className="mx-auto flex max-w-product-page items-center justify-between gap-2 p-4 max-sm:flex-col max-sm:items-stretch lg:gap-4 lg:px-8"
        style={{
          transition: "var(--transition-duration)",
          marginTop: visible || !isDesktop ? undefined : -height,
        }}
      >
        {needsOptionChoice(product, selection) ? null : (
          <PriceTag
            currencyCode={product.currency_code}
            oldPrice={discountedPriceCents < priceCents ? priceCents : undefined}
            price={discountedPriceCents}
            url={product.long_url}
            recurrence={
              product.recurrences
                ? {
                    id: selection.recurrence ?? product.recurrences.default,
                    duration_in_months: product.duration_in_months,
                  }
                : undefined
            }
            isPayWhatYouWant={isPWYW}
            isSalesLimited={product.is_sales_limited}
            creatorName={product.seller?.name}
            buyerCurrency={product.buyer_currency}
            buyerLocalCurrencyRate={product.buyer_local_currency_rate}
            buyerLocalCurrencySubunitToUnit={product.buyer_local_currency_subunit_to_unit}
            buyerLocalPriceCents={buyerLocalPriceCentsForSelection(
              product.buyer_local_price_cents,
              discountCode?.valid ? discountCode.discount : null,
              selection.quantity,
            )}
            buyerLocalOriginalPriceCents={product.buyer_local_original_price_cents}
          />
        )}
        <h3 className="hidden flex-1 lg:block">{product.name}</h3>
        {product.ratings != null && product.ratings.count > 0 ? (
          <RatingsSummary className="hidden lg:flex" ratings={product.ratings} />
        ) : null}
        <div className="flex shrink-0 items-center gap-2 max-sm:flex-col max-sm:items-stretch">
          <PurchaseButton
            product={product}
            purchase={purchase}
            discountCode={discountCode ?? null}
            selection={selection}
            label={ctaLabel}
            setSelection={setSelection}
            configurationSelectorRef={configurationSelectorRef}
          />
        </div>
      </div>
    </section>
  );
};

const EditButton = ({ product }: { product: Product }) => {
  const appDomain = useAppDomain();

  if (!product.can_edit) return null;

  return (
    <NavigationButton
      className="mb-4"
      color="filled"
      href={Routes.edit_link_url({ id: product.permalink }, { host: appDomain })}
    >
      <Pencil className="size-5" aria-hidden="true" />
      Edit product
    </NavigationButton>
  );
};
