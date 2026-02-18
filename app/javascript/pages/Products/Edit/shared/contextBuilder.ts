// app/javascript/pages/Products/Edit/shared/contextBuilder.ts
//
// Builds the ProductEditContext value from Inertia page props.
// Each tab page uses this to initialize the context that the existing
// ProductEdit components (Layout, ProductTab, ContentTab, etc.) depend on.

import * as React from "react";
import { saveProduct } from "$app/data/product_edit";
import { getDownloadUrl } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { showAlert } from "$app/components/server-components/Alert";
import { assertResponseError } from "$app/utils/request";
import type { CurrencyCode } from "$app/utils/currency";
import type { Product, ContentUpdates, ExistingFileEntry } from "$app/components/ProductEdit/state";
import type { EditPageProps } from "./types";

export interface TabContextState {
  product: Product;
  setProduct: React.Dispatch<React.SetStateAction<Product>>;
  existingFiles: ExistingFileEntry[];
  setExistingFiles: React.Dispatch<React.SetStateAction<ExistingFileEntry[]>>;
  currencyType: CurrencyCode;
  setCurrencyType: React.Dispatch<React.SetStateAction<CurrencyCode>>;
  contentUpdates: ContentUpdates;
  setContentUpdates: React.Dispatch<React.SetStateAction<ContentUpdates>>;
  saving: boolean;
  setSaving: React.Dispatch<React.SetStateAction<boolean>>;
}

export const buildContextValue = (props: EditPageProps, state: TabContextState) => {
  const {
    product,
    setProduct,
    existingFiles,
    setExistingFiles,
    currencyType,
    setCurrencyType,
    contentUpdates,
    setContentUpdates,
    saving,
    setSaving,
  } = state;

  const updateProduct = (update: Partial<Product> | ((p: Product) => void)) =>
    setProduct((prev) => {
      const updated = { ...prev };
      if (typeof update === "function") update(updated);
      else Object.assign(updated, update);
      return updated;
    });

  const save = async () => {
    try {
      setSaving(true);
      const response = await saveProduct(props.unique_permalink, props.id, product, currencyType);
      if (response.warning_message) {
        showAlert(response.warning_message, "warning");
      } else {
        showAlert("Changes saved!", "success");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setSaving(false);
    }
  };

  return {
    id: props.id,
    product,
    uniquePermalink: props.unique_permalink,
    updateProduct,
    thumbnail: props.thumbnail,
    refundPolicies: props.refund_policies,
    currencyType,
    setCurrencyType,
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
    existingFiles,
    setExistingFiles,
    awsKey: props.aws_key,
    s3Url: props.s3_url,
    availableCountries: props.available_countries,
    saving,
    save,
    googleClientId: props.google_client_id,
    googleCalendarEnabled: props.google_calendar_enabled,
    seller_refund_policy_enabled: props.seller_refund_policy_enabled,
    seller_refund_policy: props.seller_refund_policy,
    cancellationDiscountsEnabled: props.cancellation_discounts_enabled,
    contentUpdates,
    setContentUpdates,
    filesById: new Map(props.product.files.map((f) => [f.id, { ...f, url: getDownloadUrl(props.id, f) }])),
    aiGenerated: props.ai_generated,
  };
};
