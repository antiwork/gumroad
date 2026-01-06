import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { InertiaLayout, useProductUrl } from "$app/components/BundleEdit/InertiaLayout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { MarketingEmailStatus } from "$app/components/BundleEdit/ShareTab/MarketingEmailStatus";
import { Bundle, BundleEditContext } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { ProfileSection } from "$app/components/ProductEdit/state";
import { Toggle } from "$app/components/Toggle";
import { TwitterShareButton } from "$app/components/TwitterShareButton";

export type BundleShareProps = {
  bundle: Bundle;
  id: string;
  unique_permalink: string;
  currency_type: CurrencyCode;
  thumbnail: Thumbnail | null;
  sales_count_for_inventory: number;
  ratings: RatingsWithPercentages;
  taxonomies: Taxonomy[];
  profile_sections: ProfileSection[];
  refund_policies: OtherRefundPolicy[];
  products_count: number;
  is_bundle: boolean;
  has_outdated_purchases: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
};

export default function BundleShare() {
  const {
    bundle: initialBundle,
    id,
    unique_permalink,
    currency_type,
    thumbnail,
    sales_count_for_inventory,
    ratings,
    taxonomies,
    profile_sections,
    refund_policies,
    products_count,
    has_outdated_purchases,
    seller_refund_policy_enabled,
    seller_refund_policy,
  } = cast<BundleShareProps>(usePage().props);

  const [bundle, setBundle] = React.useState(initialBundle);
  React.useEffect(() => setBundle(initialBundle), [initialBundle]);
  const updateBundle = (update: Partial<Bundle> | ((bundle: Bundle) => void)) =>
    setBundle((prevBundle) => {
      if (typeof update === "function") {
        const updated = { ...prevBundle };
        update(updated);
        return updated;
      }
      return { ...prevBundle, ...update };
    });

  const currentSeller = useCurrentSeller();
  const url = useProductUrl(bundle, unique_permalink);

  // Provide context for components that might still need it (like ProductPreview)
  const contextValue = React.useMemo(
    () => ({
      bundle,
      updateBundle,
      id,
      uniquePermalink: unique_permalink,
      currencyType: currency_type,
      thumbnail,
      salesCountForInventory: sales_count_for_inventory,
      ratings,
      taxonomies,
      profileSections: profile_sections,
      refundPolicies: refund_policies,
      productsCount: products_count,
      hasOutdatedPurchases: has_outdated_purchases,
      seller_refund_policy_enabled,
      seller_refund_policy,
    }),
    [bundle],
  );

  if (!currentSeller) return null;

  return (
    <BundleEditContext.Provider value={contextValue}>
      <InertiaLayout
        currentTab="share"
        bundle={bundle}
        id={id}
        uniquePermalink={unique_permalink}
        onBundleChange={updateBundle}
        preview={<ProductPreview />}
      >
        <form>
          <section className="p-4! md:p-8!">
            <header>
              <h2>Share</h2>
            </header>
            <div className="flex flex-wrap gap-2">
              <TwitterShareButton url={url} text={`Buy ${bundle.name} on @Gumroad`} />
              <FacebookShareButton url={url} text={bundle.name} />
              <CopyToClipboard text={url} tooltipPosition="top">
                <Button color="primary">
                  <Icon name="link" />
                  Copy URL
                </Button>
              </CopyToClipboard>
            </div>
            <section>
              <MarketingEmailStatus />
            </section>
          </section>
          <ProfileSectionsEditor
            sectionIds={bundle.section_ids}
            onChange={(sectionIds) => updateBundle({ section_ids: sectionIds })}
            profileSections={profile_sections}
          />
          <section className="p-4! md:p-8!">
            <header className="flex items-center justify-between">
              <h2>Gumroad Discover</h2>
              <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            <div className="flex flex-col gap-4">
              <p>
                Gumroad Discover recommends your products to prospective customers for a flat 30% fee on each sale,
                helping you grow beyond your existing following and find even more people who care about your work.
              </p>
              <p>When enabled, the product will also become part of the Gumroad affiliate program.</p>
            </div>
            <TaxonomyEditor
              taxonomyId={bundle.taxonomy_id}
              onChange={(taxonomy_id) => updateBundle({ taxonomy_id })}
              taxonomies={taxonomies}
            />
            <TagSelector tags={bundle.tags} onChange={(tags) => updateBundle({ tags })} />
            <fieldset>
              <Toggle
                value={bundle.display_product_reviews}
                onChange={(newValue) => updateBundle({ display_product_reviews: newValue })}
              >
                Display your product's 1-5 star rating to prospective customers
              </Toggle>
              <Toggle value={bundle.is_adult} onChange={(newValue) => updateBundle({ is_adult: newValue })}>
                This product contains content meant only for adults, including the preview
              </Toggle>
            </fieldset>
          </section>
        </form>
      </InertiaLayout>
    </BundleEditContext.Provider>
  );
}
