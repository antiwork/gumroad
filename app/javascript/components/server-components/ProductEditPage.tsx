import { DirectUpload } from "@rails/activestorage";
import { isEqual } from "lodash-es";
import * as React from "react";
import { createBrowserRouter, RouteObject, RouterProvider } from "react-router-dom";
import typia from "typia";

import { saveProduct } from "$app/data/product_edit";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Seller } from "$app/components/Product";
import { ContentTab } from "$app/components/ProductEdit/ContentTab";
import { getDownloadUrl } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { Page, titleWithFallback } from "$app/components/ProductEdit/ContentTab/PageTab";
import { ProductTab } from "$app/components/ProductEdit/ProductTab";
import { ReceiptTab } from "$app/components/ProductEdit/ReceiptTab";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import { ShareTab } from "$app/components/ProductEdit/ShareTab";
import {
  ContentUpdates,
  ExistingFileEntry,
  Product,
  ProductEditContext,
  ProfileSection,
  ShippingCountry,
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
  {
    path: "/products/:id/edit/receipt",
    element: <ReceiptTab />,
    handle: "receipt",
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
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
  cancellation_discounts_enabled: boolean;
  receipt_email_from: string;
  price_checker_enabled: boolean;
  custom_html_pages_enabled: boolean;
  ai_generated: boolean;
};

const buildFilesById = (productId: string, files: Props["product"]["files"]) =>
  new Map(files.map((file) => [file.id, { ...file, url: getDownloadUrl(productId, file) }]));

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
  save: () => Promise.resolve(false),
  googleClientId: props.google_client_id,
  seller_refund_policy_enabled: props.seller_refund_policy_enabled,
  seller_refund_policy: props.seller_refund_policy,
  cancellationDiscountsEnabled: props.cancellation_discounts_enabled,
  receiptEmailFrom: props.receipt_email_from,
  priceCheckerEnabled: props.price_checker_enabled,
  customHtmlPagesEnabled: props.custom_html_pages_enabled,
  contentUpdates: null,
  setContentUpdates: () => {},
  aiGenerated: props.ai_generated,
});

const pagesHaveSameContent = (pages1: Page[], pages2: Page[]): boolean => isEqual(pages1, pages2);

// Client-side mirror of RichContent#has_editor_content?: a page counts as
// contentful when its tiptap document contains anything a buyer could see.
// A bare empty paragraph/heading (the editor's blank placeholder) is not content.
const nodeHasContent = (node: unknown): boolean => {
  if (typeof node !== "object" || node === null) return false;
  if ("text" in node && typeof node.text === "string" && node.text.length > 0) return true;
  if ("content" in node && Array.isArray(node.content)) return node.content.some(nodeHasContent);
  // Leaf nodes without a content array (fileEmbed, image, etc.) render
  // something by themselves — except empty structural placeholders.
  return !("type" in node) || (node.type !== "paragraph" && node.type !== "heading");
};

const pageHasVisibleContent = (page: Page) => {
  const description: unknown = page.description;
  return (
    typeof description === "object" &&
    description !== null &&
    "content" in description &&
    Array.isArray(description.content) &&
    description.content.some(nodeHasContent)
  );
};

// What the seller is deleting in this editor session — the pieces of the
// product that existed at the last save but are gone from the current state.
// Shown in a summary confirmation modal before the save request goes out, so
// a save that removes real content (especially a lot of it) never happens
// without one final explicit "yes".
type PendingDeletions = {
  variants: { id: string; name: string }[];
  pages: { id: string; title: string | null }[];
};

const findPendingDeletions = (product: Product, lastSavedProduct: Product): PendingDeletions => {
  // Note: deletions the seller confirmed per-row (the "Yes, remove" /
  // delete-page modals record ids into confirmed_removed_*_ids) are NOT
  // excluded here. Those ids exist to satisfy the server-side deletion guard;
  // this summary modal is deliberately a second, save-time gate — the last
  // chance to notice an accumulated (possibly large) wipe as one list before
  // it becomes permanent. Every UI deletion path records a confirmed id, so
  // excluding them would mean the summary never appears at all.
  const currentVariantIds = new Set(product.variants.map(({ id }) => id));
  // Only content-bearing variants warrant the scary confirmation — mirroring
  // the server-side guard, which protects variants with visible rich-content
  // pages OR directly-attached files (legacy products predating embedded
  // rich-content files). Contentless variants (e.g. a coffee product's
  // "suggested amounts", an empty just-added version) delete without fuss.
  const removedVariants = lastSavedProduct.variants.filter(
    ({ id, rich_content, has_files }) =>
      !currentVariantIds.has(id) && (rich_content.some(pageHasVisibleContent) || has_files === true),
  );

  // A page id that still appears anywhere in the current state (product-level
  // or under any variant) is a MOVE (e.g. toggling "use the same content for
  // all versions"), not a deletion.
  const currentPageIds = new Set([
    ...product.rich_content.map(({ id }) => id),
    ...product.variants.flatMap((variant) => variant.rich_content.map(({ id }) => id)),
  ]);
  const removedPagesById = new Map<string, Page>();
  for (const page of [
    ...lastSavedProduct.rich_content,
    ...lastSavedProduct.variants.flatMap((variant) => variant.rich_content),
  ]) {
    if (!currentPageIds.has(page.id) && pageHasVisibleContent(page)) removedPagesById.set(page.id, page);
  }

  return {
    variants: removedVariants.map(({ id, name }) => ({ id, name })),
    pages: [...removedPagesById.values()].map(({ id, title }) => ({ id, title })),
  };
};

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
  const [router] = React.useState(() => createBrowserRouter(routes));

  const [saving, setSaving] = React.useState(false);
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());
  // Deletions awaiting the seller's final confirmation in the save-time summary
  // modal. Non-null while the modal is open; the ref holds the resolver of the
  // in-flight save() promise so callers awaiting save() (e.g. "Save and
  // continue") settle once the seller decides.
  const [pendingDeletions, setPendingDeletions] = React.useState<PendingDeletions | null>(null);
  const pendingSaveRef = React.useRef<((saved: boolean) => void) | null>(null);
  // Resolves true only when the save request actually succeeded — callers that
  // chain follow-up actions on save() (navigating to the next tab, opening the
  // preview) use this to stay put when the save failed or the seller cancelled
  // the deletion confirmation.
  const performSave = async (): Promise<boolean> => {
    let saved = false;
    try {
      setSaving(true);
      const response = await saveProduct(props.unique_permalink, props.id, product, currencyType);
      saved = true;
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
    return saved;
  };
  const save = async (): Promise<boolean> => {
    // A save that deletes existing versions/tiers or content pages gets one
    // final summary confirmation before the request goes out. Each deletion
    // already had its own modal when the seller clicked delete, but this is
    // the last chance to notice an accumulated (possibly large) wipe before
    // it becomes permanent.
    const deletions = findPendingDeletions(product, lastSavedProductRef.current);
    if (deletions.variants.length + deletions.pages.length > 0) {
      setPendingDeletions(deletions);
      return new Promise<boolean>((resolve) => {
        pendingSaveRef.current = resolve;
      });
    }
    return performSave();
  };
  const confirmDeletionsAndSave = async () => {
    setPendingDeletions(null);
    const saved = await performSave();
    pendingSaveRef.current?.(saved);
    pendingSaveRef.current = null;
  };
  const cancelDeletionConfirmation = () => {
    setPendingDeletions(null);
    // Resolve as not-saved — callers chained on save() (e.g. "Save and
    // continue") stay put, the same way they do when a save request fails.
    pendingSaveRef.current?.(false);
    pendingSaveRef.current = null;
  };
  // What the product type calls its variants, matching the per-row deletion
  // modals ("Remove Tier 1?" etc.) in the Product tab editors.
  const variantLabel =
    product.native_type === "membership" ? "tier" : product.native_type === "call" ? "duration" : "version";

  const filesById = React.useMemo(() => buildFilesById(props.id, product.files), [product.files, props.id]);

  const contextValue = React.useMemo(
    () => ({
      ...createContextValue({ ...props, product }),
      setCurrencyType,
      currencyType,
      existingFiles,
      setExistingFiles,
      updateProduct,
      save,
      saving,
      contentUpdates,
      setContentUpdates,
      filesById,
    }),
    [product, updateProduct, existingFiles, setExistingFiles, filesById],
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
                .then((data) => resolve(typia.assert<{ url: string }>(data).url))
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
        {pendingDeletions ? (
          <Modal
            open
            onClose={cancelDeletionConfirmation}
            title="Save and delete content?"
            footer={
              <>
                <Button onClick={cancelDeletionConfirmation}>No, cancel</Button>
                <Button color="danger" onClick={() => void confirmDeletionsAndSave()}>
                  Yes, save and delete
                </Button>
              </>
            }
          >
            <div className="flex flex-col gap-4">
              <p>Saving now will permanently delete the following from this product:</p>
              {pendingDeletions.variants.length > 0 ? (
                <div>
                  <strong>
                    {pendingDeletions.variants.length === 1
                      ? `1 ${variantLabel}`
                      : `${pendingDeletions.variants.length} ${variantLabel}s`}
                  </strong>
                  <ul className="list-disc pl-6">
                    {pendingDeletions.variants.map(({ id, name }) => (
                      <li key={id}>{name || "Untitled"}</li>
                    ))}
                  </ul>
                </div>
              ) : null}
              {pendingDeletions.pages.length > 0 ? (
                <div>
                  <strong>
                    {pendingDeletions.pages.length === 1
                      ? "1 content page"
                      : `${pendingDeletions.pages.length} content pages`}
                  </strong>
                  <ul className="list-disc pl-6">
                    {pendingDeletions.pages.map(({ id, title }) => (
                      <li key={id}>{titleWithFallback(title)}</li>
                    ))}
                  </ul>
                </div>
              ) : null}
              <p>Customers who purchased this content will lose access to it.</p>
            </div>
          </Modal>
        ) : null}
        <RouterProvider router={router} />
      </ImageUploadSettingsContext.Provider>
    </ProductEditContext.Provider>
  );
};

export { ProductEditPage };
export type { Props as ProductEditPageProps };
