import { useForm, usePage } from "@inertiajs/react";
import Layout from "$app/inertia/layout";
import { Editor, findChildren } from "@tiptap/core";
import { DirectUpload } from "@rails/activestorage";
import * as React from "react";

import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { Taxonomy } from "$app/utils/discover";
import { Seller } from "$app/components/Product";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { baseEditorOptions } from "$app/components/RichTextEditor";
import { extensions } from "$app/components/ProductEdit/ContentTab";
import { showAlert } from "$app/components/server-components/Alert";
import { CurrencyCode } from "$app/utils/currency";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { assertResponseError, request } from "$app/utils/request";
import {
  ProductEditContext,
  Product,
  ContentUpdates,
  ExistingFileEntry,
  ProfileSection,
  ShippingCountry,
} from "$app/components/ProductEdit/state";

export type EditProps = {
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
  logged_in_user: any;
  current_seller: any;
};

export default function ProductEditLayout({ children }: { children: React.ReactNode }) {
  const props = usePage<EditProps>().props;
  const {
    id,
    product: initialProduct,
    unique_permalink: uniquePermalink,
    currency_type: initialCurrencyType,
    ai_generated: aiGenerated,
    existing_files: initialExistingFiles,
  } = props;

  const form = useForm({
    product: initialProduct,
    currencyType: initialCurrencyType,
  });

  const [contentUpdates, setContentUpdates] = React.useState<ContentUpdates>(null);
  const [existingFiles, setExistingFiles] = React.useState<ExistingFileEntry[]>(initialExistingFiles);
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());

  const lastSavedProductRef = React.useRef<Product>(structuredClone(initialProduct));

  const updateProduct = (update: Partial<Product> | ((product: Product) => void)) => {
    form.setData((prev) => {
      const currentProduct = prev.product;
      const updatedProduct = { ...currentProduct };
      if (typeof update === "function") update(updatedProduct);
      else Object.assign(updatedProduct, update);
      return { ...prev, product: updatedProduct as Product };
    });
  };

  const save = async () => {
    // Legacy logic to filter files based on rich text content
    const editor = new Editor(baseEditorOptions(extensions(id)));
    const richContents =
      form.data.product.has_same_rich_content_for_all_variants || !form.data.product.variants.length
        ? form.data.product.rich_content
        : form.data.product.variants.flatMap((variant) => variant.rich_content);

    const fileIds = new Set(
      richContents.flatMap((content) =>
        findChildren(
          editor.schema.nodeFromJSON(content.description),
          (node) => node.type.name === FileEmbed.name,
        ).map<unknown>((child) => child.node.attrs.id),
      ),
    );
    editor.destroy();

    const productToSave = {
      ...form.data.product,
      files: form.data.product.files.filter((file) => fileIds.has(file.id)),
    };

    form.transform((data) => ({
      ...productToSave,
      price_currency_type: data.currencyType,
      covers: productToSave.covers.map(({ id }) => id),
      variants: productToSave.variants.map(({ newlyAdded, ...variant }) => (newlyAdded ? { ...variant, id: null } : variant)),
      availabilities: productToSave.availabilities.map(({ newlyAdded, ...availability }) =>
        newlyAdded ? { ...availability, id: null } : availability,
      ),
      installment_plan: productToSave.allow_installment_plan ? productToSave.installment_plan : null,
    }));

    form.post(Routes.link_path(uniquePermalink), {
      preserveScroll: true,
      onSuccess: () => {
        showAlert("Changes saved!", "success");
        lastSavedProductRef.current = structuredClone(form.data.product);
      },
      onError: (errors) => {
        showAlert(Object.values(errors)[0] || "Failed to save product", "error");
      }
    });
  };

  const setCurrencyType = (newCurrencyCode: CurrencyCode) => {
    form.setData("currencyType", newCurrencyCode);
  };

  const contextValue = React.useMemo(
    () => ({
      id,
      product: form.data.product,
      uniquePermalink,
      updateProduct,
      thumbnail: props.thumbnail,
      refundPolicies: props.refund_policies,
      currencyType: form.data.currencyType,
      setCurrencyType,
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
      existingFiles,
      setExistingFiles,
      awsKey: props.aws_key,
      s3Url: props.s3_url,
      availableCountries: props.available_countries,
      saving: form.processing,
      save,
      googleClientId: props.google_client_id,
      googleCalendarEnabled: props.google_calendar_enabled,
      seller_refund_policy_enabled: props.seller_refund_policy_enabled,
      seller_refund_policy: props.seller_refund_policy,
      cancellationDiscountsEnabled: props.cancellation_discounts_enabled,
      contentUpdates,
      setContentUpdates,
      aiGenerated,
      filesById: new Map(form.data.product.files.map((f) => [f.id, f])),
    }),
    [form.data.product, form.data.currencyType, form.processing, existingFiles, contentUpdates]
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
                .then((data) => resolve((data as { url: string }).url))
                .catch((e: unknown) => {
                   assertResponseError(e);
                   reject(e);
                });
          });
        });
      },
      allowedExtensions: ALLOWED_EXTENSIONS,
    }),
    [imagesUploading.size]
  );

  return (
    <Layout>
      <ProductEditContext.Provider value={contextValue}>
        <ImageUploadSettingsContext.Provider value={imageSettings}>
          {children}
        </ImageUploadSettingsContext.Provider>
      </ProductEditContext.Provider>
    </Layout>
  );
}
