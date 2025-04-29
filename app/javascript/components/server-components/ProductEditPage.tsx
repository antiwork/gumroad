import { DirectUpload } from "@rails/activestorage";
import { isEqual } from "lodash";
import * as React from "react";
import { createBrowserRouter, RouteObject, RouterProvider } from "react-router-dom";
import { StaticRouterProvider } from "react-router-dom/server";
import { cast, createCast } from "ts-safe-cast";

import { saveProduct } from "$app/data/product_edit";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { assertResponseError, request } from "$app/utils/request";
import { buildStaticRouter, GlobalProps, register } from "$app/utils/serverComponentUtil";

import { Seller } from "$app/components/Product";
import { ContentTab } from "$app/components/ProductEdit/ContentTab";
import { Page } from "$app/components/ProductEdit/ContentTab/PageTab";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";
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

const routes: RouteObject[] = [
  {
    path: "/products/:id/edit",
    element: <ProductTab />,
    handle: "product",
  },
  {
    path: "/products/:id/edit/content",
    element: <ContentTab />,
    handle: "content",
  },
  {
    path: "/products/:id/edit/share",
    element: <ShareTab />,
    handle: "share",
  },
];

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

  const lastSavedProductRef = React.useRef<Product>(structuredClone(props.product));

  const updateProduct = (update: Partial<Product> | ((product: Product) => void)) =>
    setProduct((prevProduct) => {
      const updated = { ...prevProduct };
      if (typeof update === "function") update(updated);
      else Object.assign(updated, update);
      return updated;
    });
  const [existingFiles, setExistingFiles] = React.useState(props.existing_files);
  const router = createBrowserRouter(routes);

  const [saving, setSaving] = React.useState(false);
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());
  const save = async () => {
    try {
      setSaving(true);
      const response = await saveProduct(props.unique_permalink, props.id, product);
      if (response.warning_message) showAlert(response.warning_message, "warning");
      else {
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
        } else {
          showAlert("Changes saved!", "success");
        }
        lastSavedProductRef.current = structuredClone(product);
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setSaving(false);
  };

  const contextValue = React.useMemo(
    () => ({
      ...createContextValue(props),
      existingFiles,
      setExistingFiles,
      product,
      updateProduct,
      save,
      saving,
      contentUpdates,
      setContentUpdates,
    }),
    [product, updateProduct, existingFiles, setExistingFiles],
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

  return (
    <ProductEditContext.Provider value={contextValue}>
      <ImageUploadSettingsContext.Provider value={imageSettings}>
        <RouterProvider router={router} />
      </ImageUploadSettingsContext.Provider>
    </ProductEditContext.Provider>
  );
};

const ProductEditRouter = async (global: GlobalProps) => {
  const { router, context } = await buildStaticRouter(global, routes);
  const component = (props: Props) => (
    <ProductEditContext.Provider value={createContextValue(props)}>
      <StaticRouterProvider router={router} context={context} nonce={global.csp_nonce} />
    </ProductEditContext.Provider>
  );
  component.displayName = "ProductEditRouter";
  return component;
};

export default register({ component: ProductEditPage, ssrComponent: ProductEditRouter, propParser: createCast() });
