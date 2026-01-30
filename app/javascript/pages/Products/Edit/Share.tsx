import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { Seller } from "$app/components/Product";
import { ProductEditLayout, useProductUrl } from "$app/components/ProductEdit/InertiaLayout";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { Product, ProfileSection, ExistingFileEntry, ShippingCountry } from "$app/components/ProductEdit/state";
import { Toggle } from "$app/components/Toggle";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";

type SharePageProps = {
  product: Product;
  id: string;
  unique_permalink: string;
  thumbnail: Thumbnail | null;
  refund_policies: OtherRefundPolicy[];
  currency_type: CurrencyCode;
  is_tiered_membership: boolean;
  is_listed_on_discover: boolean;
  is_physical: boolean;
  profile_sections: ProfileSection[];
  taxonomies: Taxonomy[];
  earliest_membership_price_change_date: string;
  custom_domain_verification_status: { success: boolean; message: string } | null;
  sales_count_for_inventory: number;
  successful_sales_count: number;
  ratings: RatingsWithPercentages;
  seller: Seller;
  existing_files: ExistingFileEntry[];
  aws_key: string;
  s3_url: string;
  available_countries: ShippingCountry[];
  google_client_id: string;
  google_calendar_enabled: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
  cancellation_discounts_enabled: boolean;
  ai_generated: boolean;
};

type ShareFormData = {
  taxonomy_id: string | null;
  tags: string[];
  section_ids: string[];
  display_product_reviews: boolean;
  is_adult: boolean;
  discover_fee_per_thousand: number;
  unpublish?: boolean;
};

export default function ProductsEditShare() {
  const page = usePage();
  const props = cast<SharePageProps>(page.props);
  const {
    product,
    id,
    unique_permalink,
    profile_sections,
    taxonomies,
    is_listed_on_discover,
  } = props;

  const currentSeller = useCurrentSeller();
  const url = useProductUrl(unique_permalink, product.custom_permalink, product.native_type);
  const discoverUrl = useDiscoverUrl();

  const form = useForm<ShareFormData>({
    taxonomy_id: product.taxonomy_id,
    tags: product.tags,
    section_ids: product.section_ids,
    display_product_reviews: product.display_product_reviews,
    is_adult: product.is_adult,
    discover_fee_per_thousand: product.discover_fee_per_thousand,
  });

  const transformShareData = () => ({
    taxonomy_id: form.data.taxonomy_id,
    tags: form.data.tags,
    section_ids: form.data.section_ids,
    display_product_reviews: form.data.display_product_reviews,
    is_adult: form.data.is_adult,
    discover_fee_per_thousand: form.data.discover_fee_per_thousand,
  });

  const submitForm = (additionalData: Record<string, unknown> = {}) => {
    if (form.processing) return;
    form.transform(() => ({ ...transformShareData(), ...additionalData }));
    form.put(Routes.product_edit_share_path(unique_permalink), {
      preserveScroll: true,
    });
  };

  const handleSave = () => submitForm();
  const handleUnpublish = () => submitForm({ unpublish: true });

  if (!currentSeller) return null;

  const discoverLink = new URL(discoverUrl);
  discoverLink.searchParams.set("query", product.name);

  return (
    <ProductEditLayout
      id={id}
      name={product.name}
      customPermalink={product.custom_permalink}
      uniquePermalink={unique_permalink}
      isPublished={product.is_published}
      nativeType={product.native_type}
      currentTab="share"
      isProcessing={form.processing}
      onSave={handleSave}
      onUnpublish={handleUnpublish}
    >
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <header>
              <h2>Share</h2>
            </header>
            <div className="flex flex-wrap gap-2">
              <TwitterShareButton url={url} text={`Buy ${product.name} on @Gumroad`} />
              <FacebookShareButton url={url} text={product.name} />
              <CopyToClipboard text={url} tooltipPosition="top">
                <Button color="primary">
                  <Icon name="link" />
                  Copy URL
                </Button>
              </CopyToClipboard>
              <NavigationButton
                href={`https://gum.new?productId=${id}`}
                target="_blank"
                rel="noopener noreferrer"
                color="accent"
              >
                <Icon name="plus" />
                Create Gum
              </NavigationButton>
            </div>
          </section>
          <ProfileSectionsEditor
            sectionIds={form.data.section_ids}
            onChange={(sectionIds) => form.setData("section_ids", sectionIds)}
            profileSections={profile_sections}
          />
          <section className="p-8!">
            <header style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <h2>Gumroad Discover</h2>
              <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            {is_listed_on_discover ? (
              <Alert role="status" variant="success">
                <div className="flex flex-col justify-between sm:flex-row">
                  {product.name} is listed on Gumroad Discover.
                  <a href={discoverLink.toString()}>View</a>
                </div>
              </Alert>
            ) : (
              <Alert role="status" variant="info">
                <div className="flex flex-col justify-between sm:flex-row">
                  {product.name} is not listed on Gumroad Discover yet.
                  <a href="/help/article/79-gumroad-discover">Learn how to get listed</a>
                </div>
              </Alert>
            )}
            <TaxonomyEditor
              taxonomyId={form.data.taxonomy_id}
              onChange={(taxonomyId) => form.setData("taxonomy_id", taxonomyId)}
              taxonomies={taxonomies}
            />
            <TagSelector
              tags={form.data.tags}
              onChange={(tags) => form.setData("tags", tags)}
            />
          </section>
          <section className="p-4! md:p-8!">
            <h2>Settings</h2>
            <fieldset>
              <Toggle
                value={form.data.display_product_reviews}
                onChange={(newValue) => form.setData("display_product_reviews", newValue)}
              >
                Display product reviews on product page
              </Toggle>
              <Toggle
                value={form.data.is_adult}
                onChange={(newValue) => form.setData("is_adult", newValue)}
              >
                Mark as adult content (18+)
              </Toggle>
            </fieldset>
          </section>
        </form>
      </div>
    </ProductEditLayout>
  );
}
