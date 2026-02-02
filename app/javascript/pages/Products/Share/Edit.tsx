import { useForm, usePage } from "@inertiajs/react";
import hands from "images/illustrations/hands.png";
import * as React from "react";

import { RatingsWithPercentages } from "$app/parsers/product";
import { Taxonomy } from "$app/utils/discover";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { Seller } from "$app/components/Product";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { ProductEditContext } from "$app/components/ProductEdit/state";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";
import { Switch } from "$app/components/ui/Switch";
import { useRunOnce } from "$app/components/useRunOnce";

import { BaseProductEditPageProps, ProfileSection } from "../Shared/types";
import { EditLayout } from "../Shared/EditLayout";

type SharePageProps = BaseProductEditPageProps & {
  product: {
    name: string;
    section_ids: string[];
    taxonomy_id: string | null;
    tags: string[];
    display_product_reviews: boolean;
    is_adult: boolean;
    custom_domain: string;
    is_published?: boolean;
    native_type?: string;
    custom_permalink?: string | null;
  };
  profile_sections: ProfileSection[];
  taxonomies: Taxonomy[];
  is_listed_on_discover: boolean;
  custom_domain_verification_status: { success: boolean; message: string } | null;
  ratings: RatingsWithPercentages;
  seller: Seller;
};

type ShareFormData = {
  section_ids: string[];
  taxonomy_id: string | null;
  tags: string[];
  display_product_reviews: boolean;
  is_adult: boolean;
  custom_domain: string;
};

export default function ProductsShareEdit() {
  const page = usePage<SharePageProps>();
  const props = page.props;
  const {
    product: initialProduct,
    id,
    unique_permalink,
    profile_sections,
    taxonomies,
    is_listed_on_discover,
  } = props;

  const currentSeller = useCurrentSeller();
  const discoverUrl = useDiscoverUrl();

  const form = useForm<ShareFormData>({
    section_ids: initialProduct.section_ids,
    taxonomy_id: initialProduct.taxonomy_id,
    tags: initialProduct.tags,
    display_product_reviews: initialProduct.display_product_reviews,
    is_adult: initialProduct.is_adult,
    custom_domain: initialProduct.custom_domain,
  });

  const submitForm = (options?: { onSuccess?: () => void }) => {
    if (form.processing) return;
    form.put(Routes.product_share_path(id), {
      preserveScroll: true,
      ...(options?.onSuccess && { onSuccess: options.onSuccess }),
    });
  };

  const handleSave = async () => {
    submitForm();
  };

  // Build preview product from form data
  const previewProduct = {
    ...initialProduct,
    ...form.data,
  } as any;

  if (!currentSeller) return null;

  // Create minimal context for ProductPreview
  const contextValue = React.useMemo(
    () => ({
      id,
      product: { ...initialProduct, ...form.data } as any,
      updateProduct: () => {},
      uniquePermalink: unique_permalink,
      seller: props.seller,
      existingFiles: [],
      setExistingFiles: () => {},
      awsKey: "",
      s3Url: "",
      save: handleSave,
      saving: form.processing,
      filesById: new Map(),
      thumbnail: null,
      refundPolicies: [],
      currencyType: "usd" as any,
      setCurrencyType: () => {},
      isListedOnDiscover: is_listed_on_discover,
      isPhysical: false,
      profileSections: profile_sections,
      taxonomies,
      earliestMembershipPriceChangeDate: new Date(),
      customDomainVerificationStatus: props.custom_domain_verification_status as any,
      salesCountForInventory: 0,
      successfulSalesCount: 0,
      ratings: props.ratings,
      availableCountries: [],
      googleClientId: "",
      googleCalendarEnabled: false,
      seller_refund_policy_enabled: false,
      seller_refund_policy: { title: "", fine_print: "" },
      cancellationDiscountsEnabled: false,
      contentUpdates: null,
      setContentUpdates: () => {},
      aiGenerated: false,
    }),
    [id, initialProduct, form.data, form.processing, unique_permalink, is_listed_on_discover, profile_sections, taxonomies, props],
  );

  const url = initialProduct.custom_permalink
    ? Routes.short_link_url(initialProduct.custom_permalink, { host: currentSeller.subdomain })
    : Routes.short_link_url(unique_permalink, { host: currentSeller.subdomain });

  const discoverLink = new URL(discoverUrl);
  discoverLink.searchParams.set("query", initialProduct.name);

  return (
    <ProductEditContext.Provider value={contextValue}>
      <EditLayout
        productId={id}
        uniquePermalink={unique_permalink}
        currentTab="share"
        onSave={handleSave}
        isSaving={form.processing}
        product={previewProduct}
        preview={<ProductPreview />}
      >
      <div className="squished">
        <form>
          <section className="p-4! md:p-8!">
            <DiscoverEligibilityPromo />
            <header>
              <h2>Share</h2>
            </header>
            <div className="flex flex-wrap gap-2">
              <TwitterShareButton url={url} text={`Buy ${initialProduct.name} on @Gumroad`} />
              <FacebookShareButton url={url} text={initialProduct.name} />
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
                  {initialProduct.name} is listed on Gumroad Discover.
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
    </EditLayout>
    </ProductEditContext.Provider>
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
