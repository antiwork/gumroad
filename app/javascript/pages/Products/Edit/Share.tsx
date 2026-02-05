import { useForm, usePage } from "@inertiajs/react";
import hands from "images/illustrations/hands.png";
import * as React from "react";

import { type CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { Layout, useProductUrl } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { type Product } from "$app/components/ProductEdit/state";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";
import { Switch } from "$app/components/ui/Switch";
import { useRunOnce } from "$app/components/useRunOnce";

type ProfileSection = {
  id: string;
  header: string;
  product_names: string[];
  default: boolean;
};

type SharePageProps = {
  product: Product;
  id: string;
  unique_permalink: string;
  profile_sections: ProfileSection[];
  taxonomies: Taxonomy[];
  is_listed_on_discover: boolean;
  currency_type: CurrencyCode;
  ratings: {
    count: number;
    average: number;
    percentages: [number, number, number, number, number];
  };
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: {
    title: string;
    fine_print: string;
  };
};

export default function SharePage() {
  const props = usePage<SharePageProps>().props;
  const { product } = props;
  const currentSeller = useCurrentSeller();
  const discoverUrl = useDiscoverUrl();
  const productUrl = useProductUrl();

  const form = useForm({
    section_ids: product.section_ids,
    taxonomy_id: product.taxonomy_id,
    tags: product.tags,
    display_product_reviews: product.display_product_reviews,
    is_adult: product.is_adult,
  });

  const [contentUpdates, setContentUpdates] = React.useState<{ uniquePermalinkOrVariantIds: string[] } | null>(null);

  const handleSave = () => {
    form.patch(Routes.products_edit_share_path(props.unique_permalink), {
      preserveScroll: true,
      onSuccess: () => {
        setContentUpdates({
          uniquePermalinkOrVariantIds: [props.unique_permalink],
        });
      },
    });
  };

  const handleSaveBeforeNavigate = (targetUrl: string) => {
    if (!form.isDirty) return false;
    form.transform((data) => ({
      ...data,
      redirect_to: targetUrl,
    }));
    form.patch(Routes.products_edit_share_path(props.unique_permalink), { preserveScroll: true });
    return true;
  };

  if (!currentSeller) return null;

  const discoverLink = new URL(discoverUrl);
  discoverLink.searchParams.set("query", product.name);

  return (
    <Layout
      preview={
        <ProductPreview
          product={product}
          id={props.id}
          uniquePermalink={props.unique_permalink}
          currencyType={props.currency_type}
          ratings={props.ratings}
          seller_refund_policy_enabled={props.seller_refund_policy_enabled}
          seller_refund_policy={props.seller_refund_policy}
        />
      }
      currentTab="share"
      onSave={handleSave}
      isSaving={form.processing}
      contentUpdates={contentUpdates}
      setContentUpdates={setContentUpdates}
      onBeforeNavigate={handleSaveBeforeNavigate}
    >
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <DiscoverEligibilityPromo />
            <header>
              <h2>Share</h2>
            </header>
            <div className="flex flex-wrap gap-2">
              <TwitterShareButton url={productUrl} text={`Buy ${product.name} on @Gumroad`} />
              <FacebookShareButton url={productUrl} text={product.name} />
              <CopyToClipboard text={productUrl} tooltipPosition="top">
                <Button color="primary">
                  <Icon name="link" />
                  Copy URL
                </Button>
              </CopyToClipboard>
              <NavigationButton
                href={`https://gum.new?productId=${props.id}`}
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
            profileSections={props.profile_sections}
          />
          <section className="p-8!">
            <header style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <h2>Gumroad Discover</h2>
              <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            {props.is_listed_on_discover ? (
              <Alert role="status" variant="success">
                <div className="flex flex-col justify-between sm:flex-row">
                  {product.name} is listed on Gumroad Discover.
                  <a href={discoverLink.toString()}>View</a>
                </div>
              </Alert>
            ) : null}
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
              taxonomies={props.taxonomies}
            />
            <TagSelector tags={form.data.tags} onChange={(tags) => form.setData("tags", tags)} />
            <fieldset>
              <Switch
                checked={form.data.display_product_reviews}
                onChange={(newValue) => form.setData("display_product_reviews", !newValue)}
                label="Display your product's 1-5 star rating to prospective customers"
              />
              <Switch
                checked={form.data.is_adult}
                onChange={(newValue) => form.setData("is_adult", !newValue)}
                label={
                  <>
                    This product contains content meant{" "}
                    <a href="/help/article/156-gumroad-and-adult-content" target="_blank" rel="noreferrer">
                      only for adults,
                    </a>{" "}
                    including the preview
                  </>
                }
              />
            </fieldset>
          </section>
        </form>
      </div>
    </Layout>
  );
}

const DiscoverEligibilityPromo = () => {
  const [show, setShow] = React.useState(false);

  useRunOnce(() => {
    if (localStorage.getItem("showDiscoverEligibilityPromo") !== "false") setShow(true);
  });

  if (!show) return null;

  return (
    <Alert role="status">
      <div className="flex items-center gap-2">
        <img src={hands} alt="" className="size-12" />
        <div className="flex flex-1 flex-col gap-2">
          <div>
            To appear on Gumroad Discover, make sure to meet all the{" "}
            <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
              eligibility criteria
            </a>
            , which includes making at least one successful sale and completing the Risk Review process explained in
            detail{" "}
            <a href="/help/article/13-getting-paid" target="_blank" rel="noreferrer">
              here
            </a>
            .
          </div>
          <button
            className="w-max cursor-pointer underline all-unset"
            onClick={() => {
              localStorage.setItem("showDiscoverEligibilityPromo", "false");
              setShow(false);
            }}
          >
            Close
          </button>
        </div>
      </div>
    </Alert>
  );
};
