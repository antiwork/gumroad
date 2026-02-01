import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { AssetPreview, CustomButtonTextOption, RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { BundleEditLayout, useProductUrl } from "$app/components/BundleEdit/Layout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { MarketingEmailStatus } from "$app/components/BundleEdit/ShareTab/MarketingEmailStatus";
import { BundleProduct } from "$app/components/BundleEdit/types";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { Seller } from "$app/components/Product";
import { Attribute } from "$app/components/ProductEdit/ProductTab/AttributesEditor";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { ProfileSection, PublicFileWithStatus } from "$app/components/ProductEdit/state";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Switch } from "$app/components/ui/Switch";

type SharePageProps = {
  bundle: {
    name: string;
    description: string;
    custom_permalink: string | null;
    covers: AssetPreview[];
    collaborating_user: Seller | null;
    customizable_price: boolean;
    price_cents: number;
    suggested_price_cents: number | null;
    max_purchase_count: number | null;
    allow_installment_plan: boolean;
    installment_plan: { number_of_installments: number } | null;
    display_product_reviews: boolean;
    quantity_enabled: boolean;
    should_show_sales_count: boolean;
    custom_button_text_option: CustomButtonTextOption | null;
    custom_summary: string | null;
    custom_attributes: Attribute[];
    refund_policy: RefundPolicy;
    public_files: PublicFileWithStatus[];
    audio_previews_enabled: boolean;
    is_published: boolean;
    taxonomy_id: string | null;
    tags: string[];
    is_adult: boolean;
    section_ids: string[];
    products: BundleProduct[];
  };
  id: string;
  unique_permalink: string;
  taxonomies: Taxonomy[];
  profile_sections: ProfileSection[];
  currency_type: CurrencyCode;
  sales_count_for_inventory: number;
  ratings: RatingsWithPercentages;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
};

type ShareFormData = {
  section_ids: string[];
  taxonomy_id: string | null;
  tags: string[];
  display_product_reviews: boolean;
  is_adult: boolean;
  unpublish?: boolean;
};

export default function BundlesShareEdit() {
  const page = usePage();
  const props = cast<SharePageProps>(page.props);
  const {
    bundle,
    id,
    unique_permalink,
    taxonomies,
    profile_sections,
    currency_type,
    sales_count_for_inventory,
    ratings,
    seller_refund_policy_enabled,
    seller_refund_policy,
  } = props;

  const currentSeller = useCurrentSeller();
  const url = useProductUrl(unique_permalink, bundle.custom_permalink);

  if (!currentSeller) return null;

  const form = useForm<ShareFormData>({
    section_ids: bundle.section_ids,
    taxonomy_id: bundle.taxonomy_id,
    tags: bundle.tags,
    display_product_reviews: bundle.display_product_reviews,
    is_adult: bundle.is_adult,
  });

  const submitForm = (additionalData: Partial<ShareFormData> = {}) => {
    if (form.processing) return;
    form.transform((data) => ({ ...data, ...additionalData }));
    form.put(Routes.bundle_share_path(id), { preserveScroll: true });
  };

  const handleSave = () => submitForm();
  const handleUnpublish = () => submitForm({ unpublish: true });
  const handlePreview = () => {
    window.open(url);
  };

  return (
    <BundleEditLayout
      id={id}
      name={bundle.name}
      customPermalink={bundle.custom_permalink}
      uniquePermalink={unique_permalink}
      isPublished={bundle.is_published}
      preview={
        <ProductPreview
          bundle={bundle}
          id={id}
          uniquePermalink={unique_permalink}
          currencyType={currency_type}
          salesCountForInventory={sales_count_for_inventory}
          ratings={ratings}
          sellerRefundPolicyEnabled={seller_refund_policy_enabled}
          sellerRefundPolicy={seller_refund_policy}
        />
      }
      onSave={handleSave}
      onUnpublish={handleUnpublish}
      onPreview={handlePreview}
      isProcessing={form.processing}
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
            <MarketingEmailStatus
              id={id}
              isPublished={bundle.is_published}
              bundleName={bundle.name}
              bundlePermalink={unique_permalink}
              bundlePriceCents={bundle.price_cents}
              products={bundle.products}
              currencyType={currency_type}
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
            <Switch
              checked={form.data.display_product_reviews}
              onChange={(e) => form.setData("display_product_reviews", e.target.checked)}
              label="Display your product's 1-5 star rating to prospective customers"
            />
            <Switch
              checked={form.data.is_adult}
              onChange={(e) => form.setData("is_adult", e.target.checked)}
              label="This product contains content meant only for adults, including the preview"
            />
          </fieldset>
        </section>
      </form>
    </BundleEditLayout>
  );
}
