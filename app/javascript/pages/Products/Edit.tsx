import { useForm, usePage } from "@inertiajs/react";
import { DirectUpload } from "@rails/activestorage";
import { isEqual } from "lodash-es";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { buildProductPayload, filterFilesInContent } from "$app/data/product_edit";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { assertResponseError, request } from "$app/utils/request";

import { Seller } from "$app/components/Product";
import { ContentTab } from "$app/components/ProductEdit/ContentTab";
import { getDownloadUrl } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { Page } from "$app/components/ProductEdit/ContentTab/PageTab";
import { type TabName } from "$app/components/ProductEdit/Layout";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";
import { ReceiptTab } from "$app/components/ProductEdit/ReceiptTab";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ShareTab } from "$app/components/ProductEdit/ShareTab";
import {
  ProductEditContext,
  Product,
  ProfileSection,
  ExistingFileEntry,
  ShippingCountry,
  ContentUpdates,
} from "$app/components/ProductEdit/state";
import { ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";

type Props = {
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
  active_tab: TabName;
  errors?: Record<string, string>;
};

const createContextValue = (props: Props) => ({
  id: props.id,
  product: props.product,
  updateProduct: () => {},
  uniquePermalink: props.unique_permalink,
  refundPolicies: props.refund_policies,
  thumbnail: props.thumbnail,
  currencyType: props.currency_type,
  isTieredMembership: props.is_tiered_membership,
  isListedOnDiscover: props.is_listed_on_discover,
  isPhysical: props.is_physical,
  profileSections: props.profile_sections,
  taxonomies: props.taxonomies,
  earliestMembershipPriceChangeDate: new Date(props.earliest_membership_price_change_date),
  customDomainVerificationStatus: props.custom_domain_verification_status,
  salesCountForInventory: props.sales_count_for_inventory,
  successfulSalesCount: props.successful_sales_count,
  ratings: props.ratings,
  seller: props.seller,
  existingFiles: props.existing_files,
  setExistingFiles: () => {},
  awsKey: props.aws_key,
  s3Url: props.s3_url,
  availableCountries: props.available_countries,
  saving: false,
  save: async () => {},
  googleClientId: props.google_client_id,
  googleCalendarEnabled: props.google_calendar_enabled,
  seller_refund_policy_enabled: props.seller_refund_policy_enabled,
  seller_refund_policy: props.seller_refund_policy,
  cancellationDiscountsEnabled: props.cancellation_discounts_enabled,
  contentUpdates: null,
  setContentUpdates: () => {},
  filesById: new Map(props.product.files.map((file) => [file.id, { ...file, url: getDownloadUrl(props.id, file) }])),
  aiGenerated: props.ai_generated,
  activeTab: props.active_tab,
});

const pagesHaveSameContent = (pages1: Page[], pages2: Page[]): boolean => isEqual(pages1, pages2);

const findUpdatedContent = (product: Product, lastSavedProduct: Product) => {
  const contentUpdatedVariantIds = product.variants
    .filter((variant) => {
      const lastSavedVariant = lastSavedProduct.variants.find((v) => v.id === variant.id);
      return !pagesHaveSameContent(variant.rich_content, lastSavedVariant?.rich_content ?? []);
    })
    .map((variant) => variant.id);

  const sharedContentUpdated = !pagesHaveSameContent(product.rich_content, lastSavedProduct.rich_content);

  return {
    sharedContentUpdated,
    contentUpdatedVariantIds,
  };
};

const ProductEditPage = (props: Props) => {
  const [product, setProduct] = React.useState(props.product);
  const [contentUpdates, setContentUpdates] = React.useState<ContentUpdates>(null);
  const [currencyType, setCurrencyType] = React.useState<CurrencyCode>(props.currency_type);
  const lastSavedProductRef = React.useRef<Product>(structuredClone(props.product));

  const updateProduct = (update: Partial<Product> | ((product: Product) => void)) =>
    setProduct((prevProduct) => {
      const updated = { ...prevProduct };
      if (typeof update === "function") update(updated);
      else Object.assign(updated, update);
      return updated;
    });
  const [existingFiles, setExistingFiles] = React.useState(props.existing_files);

  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());

  const form = useForm({});

  const save = () => {
    const filteredProduct = filterFilesInContent(props.id, product);
    const payload = buildProductPayload(filteredProduct, currencyType);

    return new Promise<void>((resolve, reject) => {
      form.transform(() => payload);
      form.patch(Routes.link_path(props.unique_permalink), {
        preserveScroll: true,
        onSuccess: () => {
          const { contentUpdatedVariantIds, sharedContentUpdated } = findUpdatedContent(
            product,
            lastSavedProductRef.current,
          );
          const contentUpdated = sharedContentUpdated || contentUpdatedVariantIds.length > 0;

          if (props.successful_sales_count > 0 && contentUpdated) {
            const uniquePermalinkOrVariantIds = product.has_same_rich_content_for_all_variants
              ? [props.unique_permalink]
              : contentUpdatedVariantIds;

            setContentUpdates({
              uniquePermalinkOrVariantIds,
            });
          }
          lastSavedProductRef.current = structuredClone(product);
          resolve();
        },
        onError: (errors) => {
          const errorMessage = Object.values(errors)[0];
          if (errorMessage) showAlert(errorMessage, "error");
          reject(new Error(errorMessage ?? "Save failed"));
        },
      });
    });
  };

  React.useEffect(() => {
    if (props.errors?.base) {
      showAlert(props.errors.base, "error");
    }
  }, [props.errors]);

  const contextValue = React.useMemo(
    () => ({
      ...createContextValue({ ...props, product }),
      setCurrencyType,
      currencyType,
      existingFiles,
      setExistingFiles,
      updateProduct,
      save,
      saving: form.processing,
      contentUpdates,
      setContentUpdates,
      activeTab: props.active_tab,
    }),
    [props, product, currencyType, existingFiles, form.processing, contentUpdates],
  );

  const imageSettings = React.useMemo(
    () => ({
      isUploading: imagesUploading.size > 0,
      onUpload: (file: File) => {
        setImagesUploading((prev) => new Set(prev).add(file));
        return new Promise<string>((resolve, reject) => {
          const upload = new DirectUpload(file, Routes.rails_direct_uploads_path());
          upload.create((error, blob) => {
            setImagesUploading((prev) => {
              const updated = new Set(prev);
              updated.delete(file);
              return updated;
            });

            if (error) reject(error);
            else
              request({
                method: "GET",
                accept: "json",
                url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }),
              })
                .then((response) => response.json())
                .then((data) => resolve(cast<{ url: string }>(data).url))
                .catch((e: unknown) => {
                  assertResponseError(e);
                  reject(e);
                });
          });
        });
      },
      allowedExtensions: ALLOWED_EXTENSIONS,
    }),
    [imagesUploading.size],
  );

  const renderTab = () => {
    switch (props.active_tab) {
      case "content":
        return <ContentTab />;
      case "share":
        return <ShareTab />;
      case "receipt":
        return <ReceiptTab />;
      case "product":
      default:
        return <ProductTab />;
    }
  };

  return (
    <ProductEditContext.Provider value={contextValue}>
      <ImageUploadSettingsContext.Provider value={imageSettings}>{renderTab()}</ImageUploadSettingsContext.Provider>
    </ProductEditContext.Provider>
  );
};

function Edit() {
  const props = usePage<Props>().props;
  return <ProductEditPage {...props} />;
}

export default Edit;
