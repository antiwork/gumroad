import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Taxonomy } from "$app/utils/discover";
import { CurrencyCode } from "$app/utils/currency";
import { RatingsWithPercentages } from "$app/parsers/product";

import { BundleEditLayout } from "$app/components/BundleEdit/InertiaLayout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { MarketingEmailStatus } from "$app/components/BundleEdit/ShareTab/MarketingEmailStatus";
import { Bundle } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { ProfileSection } from "$app/components/ProductEdit/state";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { Toggle } from "$app/components/Toggle";
import { TwitterShareButton } from "$app/components/TwitterShareButton";

type Props = {
  bundle: Bundle;
  id: string;
  unique_permalink: string;
  currency_type: CurrencyCode;
  sales_count_for_inventory: number;
  ratings: RatingsWithPercentages;
  taxonomies: Taxonomy[];
  profile_sections: ProfileSection[];
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
};

export default function BundleShareEdit() {
  const props = cast<Props>(usePage().props);
  const { bundle: initialBundle, id, unique_permalink, taxonomies, profile_sections } = props;

  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();

  const url = Routes.short_link_url(unique_permalink, {
    host: currentSeller?.subdomain ?? appDomain,
  });

  const form = useForm({
    taxonomy_id: initialBundle.taxonomy_id,
    tags: initialBundle.tags,
    display_product_reviews: initialBundle.display_product_reviews,
    is_adult: initialBundle.is_adult,
    discover_fee_per_thousand: initialBundle.discover_fee_per_thousand,
    section_ids: initialBundle.section_ids,
  });

  const handleSubmit = (e?: React.FormEvent) => {
    e?.preventDefault();
    form.put(Routes.bundles_share_path(id), {
      preserveScroll: true,
    });
  };

  if (!currentSeller) return null;

  // Create a bundle object for preview compatibility
  const bundleForPreview: Bundle = {
    ...initialBundle,
    ...form.data,
  };

  return (
    <BundleEditLayout
      bundleId={id}
      bundleName={initialBundle.name}
      uniquePermalink={unique_permalink}
      isPublished={initialBundle.is_published}
      currentTab="share"
      additionalActions={
        <Button color="primary" onClick={() => handleSubmit()} disabled={form.processing}>
          {form.processing ? "Saving..." : "Save changes"}
        </Button>
      }
      preview={<ProductPreview 
        bundle={bundleForPreview}
        id={id}
        uniquePermalink={unique_permalink}
        currencyType={props.currency_type}
        salesCountForInventory={props.sales_count_for_inventory}
        ratings={props.ratings}
        sellerRefundPolicyEnabled={props.seller_refund_policy_enabled}
        sellerRefundPolicy={props.seller_refund_policy}
      />}
    >
      <form onSubmit={handleSubmit}>
        <section className="p-4! md:p-8!">
          <header>
            <h2>Share</h2>
          </header>
          <div className="flex flex-wrap gap-2">
            <TwitterShareButton url={url} text={`Buy ${initialBundle.name} on @Gumroad`} />
            <FacebookShareButton url={url} text={initialBundle.name} />
            <CopyToClipboard text={url} tooltipPosition="top">
              <Button color="primary">
                <Icon name="link" />
                Copy URL
              </Button>
            </CopyToClipboard>
          </div>
          <section>
            <MarketingEmailStatus 
              bundleId={id} 
              bundleName={initialBundle.name}
              bundle={initialBundle}
              currencyType={props.currency_type}
            />
          </section>
        </section>
        <ProfileSectionsEditor
          sectionIds={form.data.section_ids}
          onChange={(sectionIds) => form.setData("section_ids", sectionIds)}
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
            taxonomyId={form.data.taxonomy_id}
            onChange={(taxonomy_id) => form.setData("taxonomy_id", taxonomy_id)}
            taxonomies={taxonomies}
          />
          <TagSelector tags={form.data.tags} onChange={(tags) => form.setData("tags", tags)} />
          <fieldset>
            <Toggle
              value={form.data.display_product_reviews}
              onChange={(newValue) => form.setData("display_product_reviews", newValue)}
            >
              Display your product's 1-5 star rating to prospective customers
            </Toggle>
            <Toggle value={form.data.is_adult} onChange={(newValue) => form.setData("is_adult", newValue)}>
              This product contains content meant only for adults, including the preview
            </Toggle>
          </fieldset>
        </section>
      </form>
    </BundleEditLayout>
  );
}
