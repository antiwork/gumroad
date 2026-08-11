import { DirectUpload } from "@rails/activestorage";
import { isEqual } from "lodash-es";
import * as React from "react";
import { createBrowserRouter, RouteObject, RouterProvider } from "react-router-dom";
import typia from "typia";

import {
  applyRichContentPageSaveResponse,
  canonicalRichContentScope,
  HiddenVariantContentConflictError,
  reconcileConfirmedRemovalIds,
  richContentMoveSourceIds,
  SaveProductResponse,
  StaleContentConflictError,
  StaleDeletionConflictError,
  saveProduct,
} from "$app/data/product_edit";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { useDedupeInFlight } from "$app/utils/dedupeInFlight";
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
  TaxonomyAttribute,
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
  taxonomy_attributes: TaxonomyAttribute[];
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
  custom_html_store_hostnames: string[];
  custom_html_global_nav_hosts: string[];
  custom_html_global_nav_paths: string[];
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
  taxonomyAttributes: props.taxonomy_attributes,
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
  variantIdMappings: {},
  richContentIdMappings: {},
  fileIdMappings: {},
  richContentRemovedFileEmbedIds: {},
  googleClientId: props.google_client_id,
  seller_refund_policy_enabled: props.seller_refund_policy_enabled,
  seller_refund_policy: props.seller_refund_policy,
  cancellationDiscountsEnabled: props.cancellation_discounts_enabled,
  receiptEmailFrom: props.receipt_email_from,
  priceCheckerEnabled: props.price_checker_enabled,
  customHtmlPagesEnabled: props.custom_html_pages_enabled,
  customHtmlStoreHostnames: props.custom_html_store_hostnames,
  customHtmlGlobalNavHosts: props.custom_html_global_nav_hosts,
  customHtmlGlobalNavPaths: props.custom_html_global_nav_paths,
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
  // A titled page is seller-authored work even with an empty body — the title
  // renders in the buyer's page list (mirrors the server-side rule).
  if (page.title?.trim()) return true;
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

// Swaps the editor's client-generated ids for the canonical server ids a save
// response reports (variants and pages created by that save). Without this,
// the next save would submit the same records under ids the server doesn't
// know — re-creating them and tripping the content deletion guard (see the
// server's Product::RichContentDeletionGuard).
type ScopedPage = { page: Page; scope: string | null };

// A page's client-generated id is unique WITHIN a scope, not across the whole
// payload — a product-level page and a variant page (or two variants') can
// legitimately carry the same id mid-move (gumroad-private#2023: the toggle
// between shared and per-tier content passes pages through both scopes in
// one save). Keying the lookup on id alone let the second scope's entry
// silently clobber the first in the Map, so reconciliation read the WRONG
// scope's sent snapshot for a page — corrupting its move_source_scope/
// source_id bookkeeping and making the next save reference the same
// underlying row from two scopes at once (the "references the same content
// page more than once" guard). Scope-qualify the key so same-id pages in
// different scopes stay distinct entries.
const scopedPageKey = (scope: string | null, id: string) => `${scope ?? ""}\u0000${id}`;

const allScopedRichContentPages = (product: Product): ScopedPage[] => [
  ...product.rich_content.map((page) => ({ page, scope: null })),
  ...product.variants.flatMap((variant) => variant.rich_content.map((page) => ({ page, scope: variant.id }))),
];

const applyCanonicalIds = (
  product: Product,
  response: SaveProductResponse,
  sentPagesById: ReadonlyMap<string, ScopedPage> = new Map(),
) => {
  const variantMappings = response.variant_id_mappings ?? {};
  const fileMappings = response.file_id_mappings ?? {};
  const variantTimestamps = response.variant_updated_at ?? {};
  const variantBaselines = response.variant_loaded_integrations ?? {};
  // Adopt the revision token for the state this save committed. The token the
  // page loaded with describes the pre-save snapshot, and the save moved it, so
  // keeping the old one would make the next deletion in this session look like
  // it came from a stale tab and be silently refused.
  if (response.editor_revision) product.editor_revision = response.editor_revision;
  // Adopt the refreshed integrations baseline for the same reason. It records
  // which integrations were connected as of the state this save committed; an
  // integration connected earlier in this session is only in that baseline
  // once the save that connected it has returned. Without adopting it,
  // connect -> save -> disconnect -> save (no reload) emits no deletion,
  // because the stale baseline still says the integration was never on.
  if (response.loaded_integrations) product.loaded_integrations = response.loaded_integrations;
  // Replace the array, don't mutate entries: `filesById` memoizes on
  // `product.files` identity, and the mounted editor's node ids are remapped to
  // the canonical ids in the same commit. A stale Map misses every lookup and
  // the embed renders blank.
  product.files = product.files.map((file) => {
    const canonicalId = fileMappings[file.id];
    return canonicalId ? { ...file, id: canonicalId } : file;
  });
  for (const variant of product.variants) {
    const canonicalId = variantMappings[variant.id];
    if (canonicalId) {
      variant.id = canonicalId;
      // The variant exists server-side now; later saves must address it by id
      // instead of asking for another creation.
      delete variant.newlyAdded;
    }
    // Adopt the fresh post-save snapshot timestamp so the next save echoes
    // the value this save produced — echoing the pre-save one would trip the
    // server's stale-write guard against our own save.
    const variantTimestamp = variantTimestamps[variant.id];
    if (variantTimestamp) variant.updated_at = variantTimestamp;
    // Adopt this version's refreshed integrations baseline, for the same reason
    // as the product-level one above. Read after the id remap so a version
    // created by this save is keyed by its canonical server id.
    const variantBaseline = variantBaselines[variant.id];
    if (variantBaseline) variant.loaded_integrations = variantBaseline;
    for (const page of variant.rich_content) {
      const sent = sentPagesById.get(scopedPageKey(variant.id, page.id));
      applyRichContentPageSaveResponse(
        page,
        response,
        sent?.page ?? page,
        variant.id,
        canonicalRichContentScope(sent?.scope, variantMappings),
      );
    }
  }
  for (const page of product.rich_content) {
    const sent = sentPagesById.get(scopedPageKey(null, page.id));
    applyRichContentPageSaveResponse(
      page,
      response,
      sent?.page ?? page,
      null,
      canonicalRichContentScope(sent?.scope, variantMappings),
    );
  }
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
  // Hidden version-level pages the server refused to delete without an
  // explicit choice (see HiddenVariantContentConflictError). Non-null while
  // the choice modal is open.
  const [hiddenContentConflict, setHiddenContentConflict] = React.useState<
    { id: string; title: string | null; variant_name: string | null }[] | null
  >(null);
  // Pages/variants the server refused to overwrite because this session's
  // snapshot is older than the stored rows (another session saved in
  // between). Non-null while the reload modal is open.
  const [staleContentConflict, setStaleContentConflict] = React.useState<
    { type: "page" | "variant"; id: string; name: string | null }[] | null
  >(null);
  // The save contract refused this session's deletions because its snapshot
  // token is stale. Distinct from staleContentConflict above: that one is "your
  // write would clobber newer content", this one is "your deletion was not
  // applied". Nothing was written either way, so the recovery is the same
  // reload — the seller has to re-confirm the deletion against current content,
  // because this session cannot tell which of its own field values are also
  // stale.
  const [staleDeletionConflict, setStaleDeletionConflict] = React.useState<string | null>(null);
  // Client-generated id → canonical server id, accumulated separately because
  // variant and page external ids are not distinct namespaces.
  const [variantIdMappings, setVariantIdMappings] = React.useState<Record<string, string>>({});
  const [richContentIdMappings, setRichContentIdMappings] = React.useState<Record<string, string>>({});
  const [fileIdMappings, setFileIdMappings] = React.useState<Record<string, string>>({});
  const [richContentRemovedFileEmbedIds, setRichContentRemovedFileEmbedIds] = React.useState<Record<string, string[]>>(
    {},
  );
  // Resolves true only when the save request actually succeeded — callers that
  // chain follow-up actions on save() (navigating to the next tab, opening the
  // preview) use this to stay put when the save failed or the seller cancelled
  // the deletion confirmation.
  //
  // conflictResolution: the seller's choice from the hidden-content conflict
  // dialog ("Choose which content to keep"):
  // - keep_shared: delete the listed hidden version pages (their ids go into
  //   confirmed_removed_rich_content_ids) and keep the product-level content.
  // - keep_version: delete the product-level pages, turn off "use the same
  //   content for all versions", and preserve the hidden version pages (their
  //   ids go into preserved_rich_content_ids — they can't appear in the
  //   payload because this editor session never loaded them).
  const performSave = async (conflictResolution?: {
    choice: "keep_shared" | "keep_version";
    hiddenPageIds: string[];
  }): Promise<boolean> => {
    let saved = false;
    let productToSave = product;
    if (conflictResolution?.choice === "keep_shared") {
      productToSave = {
        ...product,
        confirmed_removed_rich_content_ids: [
          ...(product.confirmed_removed_rich_content_ids ?? []),
          ...conflictResolution.hiddenPageIds,
        ],
      };
    } else if (conflictResolution?.choice === "keep_version") {
      productToSave = {
        ...product,
        has_same_rich_content_for_all_variants: false,
        rich_content: [],
        confirmed_removed_rich_content_ids: [
          ...(product.confirmed_removed_rich_content_ids ?? []),
          ...product.rich_content.map(({ id }) => id),
        ],
        preserved_rich_content_ids: conflictResolution.hiddenPageIds,
      };
    }
    // Freeze the exact request snapshot before awaiting the network. The seller
    // can keep editing while a save runs; response reconciliation must update
    // those later edits without pretending they were part of this request.
    const sentConfirmedPageIds = new Set(productToSave.confirmed_removed_rich_content_ids ?? []);
    const productSent = structuredClone(productToSave);
    productSent.confirmed_removed_rich_content_ids = [
      ...new Set([...(productSent.confirmed_removed_rich_content_ids ?? []), ...richContentMoveSourceIds(productSent)]),
    ];
    const sentPagesById = new Map(
      allScopedRichContentPages(productSent).map((scopedPage) => [
        scopedPageKey(scopedPage.scope, scopedPage.page.id),
        scopedPage,
      ]),
    );
    const sentConfirmedVariantIds = new Set(productSent.confirmed_removed_variant_ids ?? []);
    try {
      setSaving(true);
      const response = await saveProduct(props.unique_permalink, props.id, productSent, currencyType, {
        keepAllFiles: conflictResolution?.choice === "keep_version",
      });
      saved = true;
      // The version pages the seller chose to keep were never loaded into this
      // editor session (the shared-content flag hid them), so the in-memory
      // state can't render the outcome. Reload to pick up the kept content.
      if (conflictResolution?.choice === "keep_version") {
        window.location.reload();
        return true;
      }
      // Compute the changed-content diff before the baseline moves.
      const { contentUpdatedVariantIds, sharedContentUpdated } = findUpdatedContent(
        productSent,
        lastSavedProductRef.current,
      );

      // Adopt the canonical ids the server assigned to records this save
      // created, both in the live state and in the new baseline, and drop the
      // confirmed-removal ids this save consumed (the deletions are now
      // persisted; keeping them could authorize a future unintended deletion).
      // Runs for warning responses too — the save succeeded, so the baseline
      // must move or the next save would re-confirm (and re-report) changes
      // that are already persisted.
      const reconciled = structuredClone(productSent);
      applyCanonicalIds(reconciled, response, sentPagesById);
      reconciled.confirmed_removed_variant_ids = [];
      reconciled.confirmed_removed_rich_content_ids = [];
      lastSavedProductRef.current = reconciled;
      setVariantIdMappings((previous) => ({ ...previous, ...response.variant_id_mappings }));
      setRichContentIdMappings((previous) => ({ ...previous, ...response.rich_content_id_mappings }));
      setFileIdMappings((previous) => ({ ...previous, ...response.file_id_mappings }));
      setRichContentRemovedFileEmbedIds(response.rich_content_removed_file_embed_ids ?? {});
      updateProduct((current) => {
        applyCanonicalIds(current, response, sentPagesById);
        current.confirmed_removed_variant_ids = reconcileConfirmedRemovalIds(
          current.confirmed_removed_variant_ids ?? [],
          sentConfirmedVariantIds,
          response.variant_id_mappings,
        );
        current.confirmed_removed_rich_content_ids = reconcileConfirmedRemovalIds(
          current.confirmed_removed_rich_content_ids ?? [],
          sentConfirmedPageIds,
          response.rich_content_id_mappings,
        );
      });

      if (response.warning_message) showAlert(response.warning_message, "warning");
      else {
        const contentUpdated = sharedContentUpdated || contentUpdatedVariantIds.length > 0;

        if (props.successful_sales_count > 0 && contentUpdated) {
          const uniquePermalinkOrVariantIds = productSent.has_same_rich_content_for_all_variants
            ? [props.unique_permalink]
            : // Report canonical ids for variants created by this very save.
              contentUpdatedVariantIds.map((id) => response.variant_id_mappings?.[id] ?? id);

          setContentUpdates({
            uniquePermalinkOrVariantIds,
          });
        } else {
          showAlert("Changes saved!", "success");
        }
      }
    } catch (e) {
      if (e instanceof HiddenVariantContentConflictError) {
        setHiddenContentConflict(e.hiddenPages);
      } else if (e instanceof StaleContentConflictError) {
        setStaleContentConflict(e.staleRecords);
      } else if (e instanceof StaleDeletionConflictError) {
        // Nothing was written, so this is not a partially-applied save. But the
        // session cannot recover on its own: resending this snapshot with a
        // fresh token would delete what the seller asked for AND revert every
        // field a co-editor changed in between, because the payload is the
        // whole product and the write path is not gated on the token. So say
        // plainly that the deletion did not happen and send them to a reload.
        setStaleDeletionConflict(e.message);
      } else {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    }
    setSaving(false);
    return saved;
  };
  const runSave = (): Promise<boolean> => {
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
  const saveKey = React.useMemo(() => ({ product, currencyType }), [product, currencyType]);
  const save = useDedupeInFlight(saveKey, runSave, (saved) => saved);
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
      variantIdMappings,
      richContentIdMappings,
      fileIdMappings,
      richContentRemovedFileEmbedIds,
      contentUpdates,
      setContentUpdates,
      filesById,
    }),
    [
      product,
      updateProduct,
      existingFiles,
      setExistingFiles,
      filesById,
      variantIdMappings,
      richContentIdMappings,
      fileIdMappings,
      richContentRemovedFileEmbedIds,
    ],
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
        {hiddenContentConflict ? (
          <Modal
            open
            onClose={() => setHiddenContentConflict(null)}
            title="Choose which content to keep"
            footer={
              <>
                <Button onClick={() => setHiddenContentConflict(null)}>Cancel</Button>
                <Button
                  color="danger"
                  onClick={() => {
                    const hiddenPageIds = hiddenContentConflict.map(({ id }) => id);
                    setHiddenContentConflict(null);
                    void performSave({ choice: "keep_shared", hiddenPageIds });
                  }}
                >
                  Keep shared content
                </Button>
                <Button
                  color="danger"
                  onClick={() => {
                    const hiddenPageIds = hiddenContentConflict.map(({ id }) => id);
                    setHiddenContentConflict(null);
                    void performSave({ choice: "keep_version", hiddenPageIds });
                  }}
                >
                  Keep {variantLabel} content
                </Button>
              </>
            }
          >
            <div className="flex flex-col gap-4">
              <p>This product has shared content and separate content for these {variantLabel}s:</p>
              <ul className="list-disc pl-6">
                {hiddenContentConflict.map(({ id, title, variant_name }) => (
                  <li key={id}>
                    {variant_name ? `${variant_name}: ` : null}
                    {titleWithFallback(title)}
                  </li>
                ))}
              </ul>
              <p>
                Gumroad will permanently delete the content you don't keep. "Keep shared content" deletes the{" "}
                {variantLabel} pages listed above. "Keep {variantLabel} content" deletes the shared pages and turns off
                "Use the same content for all {variantLabel}s."
              </p>
            </div>
          </Modal>
        ) : null}
        {staleContentConflict ? (
          <Modal
            open
            onClose={() => setStaleContentConflict(null)}
            title="This product changed since you opened it"
            footer={
              <>
                <Button onClick={() => setStaleContentConflict(null)}>Keep editing</Button>
                <Button color="accent" onClick={() => window.location.reload()}>
                  Reload page
                </Button>
              </>
            }
          >
            <div className="flex flex-col gap-4">
              <p>
                Someone else — or another tab — saved changes to this product after this page was loaded. Saving now
                would overwrite their changes to:
              </p>
              <ul className="list-disc pl-6">
                {staleContentConflict.map(({ type, id, name }) => (
                  <li key={id}>
                    {titleWithFallback(name)}
                    {type === "variant" ? ` (${variantLabel})` : null}
                  </li>
                ))}
              </ul>
              <p>
                Nothing was saved. Reload the page to get the latest content — your unsaved edits in this session will
                be lost, so copy anything you need first.
              </p>
            </div>
          </Modal>
        ) : null}
        {staleDeletionConflict ? (
          <Modal
            open
            onClose={() => setStaleDeletionConflict(null)}
            title="Your deletion was not applied"
            footer={
              <>
                <Button onClick={() => setStaleDeletionConflict(null)}>Keep editing</Button>
                <Button color="accent" onClick={() => window.location.reload()}>
                  Reload page
                </Button>
              </>
            }
          >
            <div className="flex flex-col gap-4">
              <p>
                This product changed after you opened it, so nothing was saved — including the items you asked to
                delete. Deleting from an outdated view could remove the wrong thing.
              </p>
              <p>
                Reload the page to get the latest content, then delete again. Your unsaved edits in this session will be
                lost, so copy anything you need first.
              </p>
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
