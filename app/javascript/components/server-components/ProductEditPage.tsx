import { DirectUpload } from "@rails/activestorage";
import { isEqual } from "lodash-es";
import * as React from "react";
import { createBrowserRouter, RouteObject, RouterProvider } from "react-router-dom";
import typia from "typia";

import {
  applyRichContentPageSaveResponse,
  canonicalRichContentScope,
  hasMoveSourceScope,
  HiddenVariantContentConflictError,
  reconcileConfirmedRemovalIds,
  richContentMoveSourceIds,
  SaveProductResponse,
  StaleContentConflictError,
  StaleDeletionConflictError,
  saveProduct,
  scopedRichContentPageKey,
} from "$app/data/product_edit";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { CurrencyCode } from "$app/utils/currency";
import { useDedupeInFlight } from "$app/utils/dedupeInFlight";
import { Taxonomy } from "$app/utils/discover";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import GuidGenerator from "$app/utils/guid_generator";
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
  reconcileCustomizablePrice,
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

// reconciliation_id is save plumbing, not content: the first save stamps
// pages that the baseline clone predates, and that difference must not read
// as a content change (it would offer customer notifications for pages the
// seller never touched).
const pagesHaveSameContent = (pages1: Page[], pages2: Page[]): boolean =>
  isEqual(
    pages1.map(({ reconciliation_id: _, ...page }) => page),
    pages2.map(({ reconciliation_id: _, ...page }) => page),
  );

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

// Splits the missing-from-state diff on recorded intent: every UI deletion
// path writes the removed id into confirmed_removed_*_ids, so a missing id
// on that list is a seller deletion (summary modal) and one off it is lost
// browser state (gumroad-private#2023) — the save must stop and offer a
// reload rather than present the loss as a deletion.
const findPendingDeletions = (
  product: Product,
  lastSavedProduct: Product,
): { confirmed: PendingDeletions; unexpected: PendingDeletions } => {
  const currentVariantIds = new Set(product.variants.map(({ id }) => id));
  // Only content-bearing variants warrant the scary confirmation, mirroring
  // the server-side guard; contentless ones delete without fuss.
  const removedVariants = lastSavedProduct.variants.filter(
    ({ id, rich_content, has_files }) =>
      !currentVariantIds.has(id) && (rich_content.some(pageHasVisibleContent) || has_files === true),
  );

  const currentPages = [...product.rich_content, ...product.variants.flatMap((variant) => variant.rich_content)];
  const currentPageIds = new Set(currentPages.map(({ id }) => id));
  const currentPageStamps = new Set(
    currentPages.flatMap((page) => (page.reconciliation_id ? [page.reconciliation_id] : [])),
  );
  // A page still present somewhere in current state was moved, not deleted.
  // Presence is judged by the send-time stamp when the baseline has one: raw
  // ids can repeat across scopes, so a same-id page in another scope proves
  // nothing about THIS page. Unstamped baselines (no save this session yet)
  // hold server-loaded pages with unique ids, so the raw id suffices there.
  const pageStillPresent = (page: Page) =>
    page.reconciliation_id ? currentPageStamps.has(page.reconciliation_id) : currentPageIds.has(page.id);
  const removedPagesById = new Map<string, Page>();
  for (const page of [
    ...lastSavedProduct.rich_content,
    ...lastSavedProduct.variants.flatMap((variant) => variant.rich_content),
  ]) {
    if (!pageStillPresent(page) && pageHasVisibleContent(page)) removedPagesById.set(page.id, page);
  }

  // Removing a variant records its pages' ids too, so a page-level confirmed
  // id is the single test for intent.
  const confirmedVariantIds = new Set(product.confirmed_removed_variant_ids ?? []);
  const confirmedPageIds = new Set(product.confirmed_removed_rich_content_ids ?? []);
  const variants = removedVariants.map(({ id, name }) => ({ id, name }));
  const pages = [...removedPagesById.values()].map(({ id, title }) => ({ id, title }));
  return {
    confirmed: {
      variants: variants.filter(({ id }) => confirmedVariantIds.has(id)),
      pages: pages.filter(({ id }) => confirmedPageIds.has(id)),
    },
    unexpected: {
      variants: variants.filter(({ id }) => !confirmedVariantIds.has(id)),
      pages: pages.filter(({ id }) => !confirmedPageIds.has(id)),
    },
  };
};

// Swaps the editor's client-generated ids for the canonical server ids a save
// response reports (variants and pages created by that save). Without this,
// the next save would submit the same records under ids the server doesn't
// know — re-creating them and tripping the content deletion guard (see the
// server's Product::RichContentDeletionGuard).
type ScopedPage = { page: Page; scope: string | null };

// A page's client-generated id is only unique WITHIN a scope, not across the
// whole payload (gumroad-private#2023). Key the lookup on scope+id so pages
// sharing a raw id in different scopes don't clobber each other in the Map.
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
  // Matching sent snapshots to current pages must be one-to-one: raw ids can
  // repeat across scopes, and moves land while the request runs, so a page's
  // current scoped key can point at ANOTHER page's sent entry (a chained
  // move: A's page now sits in B while B's page moved on to C). The
  // reconciliation_id stamped on every page at send time is exact identity —
  // moves spread the page object, so the stamp travels with it. The passes
  // after it recover pages whose stamp was lost to a flow that rebuilt the
  // object, in confidence order, computed before the loops below rewrite ids
  // in place:
  //   1. an unmarked page sits where it was sent — its scoped key is identity;
  //   2. a marked page whose scoped entry carries the SAME marker was sent in
  //      place (its move predates the request);
  //   3. a marked page's move began mid-flight from move_source_scope, so
  //      that scope's entry is its snapshot (unless two pages contend);
  //   4. a leftover page takes the only unclaimed entry with its raw id.
  // Whatever stays unmatched reconciles without a snapshot, which skips the
  // move bookkeeping rather than guessing (fail-safe).
  const sentPageMatches = new Map<Page, ScopedPage>();
  const claimedSentKeys = new Set<string>();
  const currentScopedPages = allScopedRichContentPages(product);
  const claimMatch = (page: Page, key: string) => {
    if (sentPageMatches.has(page)) return;
    const snapshot = sentPagesById.get(key);
    if (!snapshot || claimedSentKeys.has(key)) return;
    sentPageMatches.set(page, snapshot);
    claimedSentKeys.add(key);
  };
  const sentPagesByReconciliationId = new Map<string, ScopedPage>();
  for (const snapshot of sentPagesById.values()) {
    if (snapshot.page.reconciliation_id) sentPagesByReconciliationId.set(snapshot.page.reconciliation_id, snapshot);
  }
  for (const { page } of currentScopedPages) {
    const snapshot = page.reconciliation_id ? sentPagesByReconciliationId.get(page.reconciliation_id) : undefined;
    if (snapshot) claimMatch(page, scopedRichContentPageKey(snapshot.scope, snapshot.page.id));
  }
  for (const { page, scope } of currentScopedPages) {
    if (!hasMoveSourceScope(page)) claimMatch(page, scopedRichContentPageKey(scope, page.id));
  }
  for (const { page, scope } of currentScopedPages) {
    if (sentPageMatches.has(page) || !hasMoveSourceScope(page)) continue;
    const key = scopedRichContentPageKey(scope, page.id);
    const snapshot = sentPagesById.get(key);
    if (
      snapshot &&
      hasMoveSourceScope(snapshot.page) &&
      snapshot.page.move_source_scope === page.move_source_scope &&
      snapshot.page.move_source_id === page.move_source_id
    ) {
      claimMatch(page, key);
    }
  }
  const markerContenders = new Map<string, Page[]>();
  for (const { page } of currentScopedPages) {
    if (sentPageMatches.has(page) || !hasMoveSourceScope(page)) continue;
    const key = scopedRichContentPageKey(page.move_source_scope ?? null, page.id);
    if (!sentPagesById.has(key) || claimedSentKeys.has(key)) continue;
    markerContenders.set(key, [...(markerContenders.get(key) ?? []), page]);
  }
  for (const [key, pages] of markerContenders) {
    if (pages.length === 1 && pages[0]) claimMatch(pages[0], key);
  }
  const unclaimedSentPagesByRawId = new Map<string, ScopedPage | null>();
  for (const [key, snapshot] of sentPagesById) {
    if (claimedSentKeys.has(key)) continue;
    unclaimedSentPagesByRawId.set(snapshot.page.id, unclaimedSentPagesByRawId.has(snapshot.page.id) ? null : snapshot);
  }
  const rawIdContenders = new Map<string, Page[]>();
  for (const { page } of currentScopedPages) {
    if (sentPageMatches.has(page) || !unclaimedSentPagesByRawId.get(page.id)) continue;
    rawIdContenders.set(page.id, [...(rawIdContenders.get(page.id) ?? []), page]);
  }
  for (const [rawId, pages] of rawIdContenders) {
    const snapshot = unclaimedSentPagesByRawId.get(rawId);
    if (snapshot && pages.length === 1 && pages[0]) {
      claimMatch(pages[0], scopedRichContentPageKey(snapshot.scope, snapshot.page.id));
    }
  }
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
    // sentPagesById is keyed by the id this variant was SENT under, which for
    // a variant created by this very save is the local id, not the canonical
    // one assigned below — capture it before the remap or every page lookup
    // for a newly-created variant misses (gumroad-private#2023 follow-up).
    const sentVariantId = variant.id;
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
      const sent = sentPageMatches.get(page);
      applyRichContentPageSaveResponse(
        page,
        response,
        sent?.page ?? page,
        variant.id,
        canonicalRichContentScope(sent?.scope, variantMappings),
        // The server keyed this page's mapping by the scope it was SENT
        // under, which for an in-flight move is not the current one.
        sent !== undefined ? sent.scope : sentVariantId,
      );
    }
  }
  for (const page of product.rich_content) {
    const sent = sentPageMatches.get(page);
    applyRichContentPageSaveResponse(
      page,
      response,
      sent?.page ?? page,
      null,
      canonicalRichContentScope(sent?.scope, variantMappings),
      sent !== undefined ? sent.scope : null,
    );
  }
};

// Remaps confirmed page removals through the response's SCOPED id mappings:
// the flat map is last-write-wins across scopes, and a raw id sent in two
// scopes could remap a deletion onto a row the seller kept. Disagreeing
// scopes tiebreak on the confirmed-removed variant; failing that the remap
// is dropped, which can only block a save (unmapped ids are inert).
const scopedConfirmedPageIdMappings = (
  response: SaveProductResponse,
  sentPagesById: ReadonlyMap<string, ScopedPage>,
  confirmedRemovedVariantIds: string[],
): Record<string, string> => {
  const byScope = response.rich_content_id_mappings_by_scope;
  const mappings = { ...response.rich_content_id_mappings };
  if (!byScope) return mappings;

  const canonicalsByRawId = new Map<string, Map<string, string>>();
  for (const scopedPage of sentPagesById.values()) {
    const scopeKey = scopedPage.scope ?? "";
    const canonical = byScope[scopeKey]?.[scopedPage.page.id];
    if (!canonical) continue;
    const perScope = canonicalsByRawId.get(scopedPage.page.id) ?? new Map<string, string>();
    perScope.set(scopeKey, canonical);
    canonicalsByRawId.set(scopedPage.page.id, perScope);
  }

  const confirmedVariantIds = new Set(confirmedRemovedVariantIds);
  const ambiguousRawIds = new Set<string>();
  for (const [rawId, perScope] of canonicalsByRawId) {
    const [onlyCanonical, ...others] = new Set(perScope.values());
    if (onlyCanonical && others.length === 0) {
      mappings[rawId] = onlyCanonical;
      continue;
    }
    const removedScopeCanonicals = [...perScope.entries()].filter(([scopeKey]) => confirmedVariantIds.has(scopeKey));
    const tiebreak = removedScopeCanonicals.length === 1 ? removedScopeCanonicals[0] : undefined;
    if (tiebreak) {
      mappings[rawId] = tiebreak[1];
    } else {
      ambiguousRawIds.add(rawId);
    }
  }
  if (ambiguousRawIds.size === 0) return mappings;
  const unambiguousMappings: Record<string, string> = {};
  for (const rawId in mappings) {
    const canonical = mappings[rawId];
    if (canonical && !ambiguousRawIds.has(rawId)) unambiguousMappings[rawId] = canonical;
  }
  return unambiguousMappings;
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
  // Products predating the backend guard can load with a PWYW flag the guard
  // would clear on the next save; reconcile up front so the editor and preview
  // never show a state that can't survive a save.
  const [product, setProduct] = React.useState<Product>(() => ({
    ...props.product,
    customizable_price: reconcileCustomizablePrice(
      props.product,
      props.product.price_cents,
      props.product.customizable_price,
    ),
  }));
  const [contentUpdates, setContentUpdates] = React.useState<ContentUpdates>(null);
  const [currencyType, setCurrencyType] = React.useState<CurrencyCode>(props.currency_type);
  const lastSavedProductRef = React.useRef<Product>(structuredClone(props.product));
  // The seller's PWYW choice as of the last nonzero base price — what a dip to
  // $0 (which forces the flag either way) restores when the price comes back.
  const priorCustomizablePriceRef = React.useRef(
    props.product.price_cents === 0 ? false : props.product.customizable_price,
  );

  const updateProduct = (update: Partial<Product> | ((product: Product) => void)) =>
    setProduct((prevProduct) => {
      const updated = { ...prevProduct };
      if (typeof update === "function") update(updated);
      else Object.assign(updated, update);
      // Every state write passes through here, so price and variant edits from
      // any tab keep the PWYW flag consistent with the backend guard. The ref
      // write is idempotent — replays of this updater converge on the same value.
      updated.customizable_price = reconcileCustomizablePrice(
        updated,
        prevProduct.price_cents,
        priorCustomizablePriceRef.current,
      );
      if (updated.price_cents !== 0) priorCustomizablePriceRef.current = updated.customizable_price;
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
  // Content present at the last save but gone from browser state without any
  // recorded deletion intent. Non-null while the reload modal is open; every
  // save attempt is blocked until the seller reloads (see runSave).
  const [missingContentConflict, setMissingContentConflict] = React.useState<PendingDeletions | null>(null);
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
    // Stamp every page with its client-only identity before freezing the
    // snapshot: reconciliation matches each page back to its sent snapshot by
    // this stamp, because scope, id, and move marker together cannot always
    // tell same-id pages apart once moves land mid-request (see Page).
    // Stamping mutates the live page objects on purpose — the seller's moves
    // spread those objects, carrying the stamp to wherever the page is when
    // the response returns.
    for (const page of [
      ...productToSave.rich_content,
      ...productToSave.variants.flatMap((variant) => variant.rich_content),
    ]) {
      page.reconciliation_id ??= GuidGenerator.generate();
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
        scopedRichContentPageKey(scopedPage.scope, scopedPage.page.id),
        scopedPage,
      ]),
    );
    const sentConfirmedVariantIds = new Set(productSent.confirmed_removed_variant_ids ?? []);
    try {
      setSaving(true);
      const response = await saveProduct(props.unique_permalink, props.id, productSent, currencyType, {
        keepAllFiles: conflictResolution?.choice === "keep_version",
        lastSavedCustomPermalink: lastSavedProductRef.current.custom_permalink,
        lastSavedCustomizablePrice: lastSavedProductRef.current.customizable_price,
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
      setRichContentIdMappings((previous) => {
        const scopedMappings = Object.entries(response.rich_content_id_mappings_by_scope ?? {}).flatMap(
          ([scope, mappings]) => {
            const canonicalScope = scope === "" ? null : (response.variant_id_mappings?.[scope] ?? scope);
            return Object.entries(mappings).map(
              ([id, canonicalId]) => [scopedRichContentPageKey(canonicalScope, id), canonicalId] as const,
            );
          },
        );
        return { ...previous, ...response.rich_content_id_mappings, ...Object.fromEntries(scopedMappings) };
      });
      setFileIdMappings((previous) => ({ ...previous, ...response.file_id_mappings }));
      setRichContentRemovedFileEmbedIds(response.rich_content_removed_file_embed_ids ?? {});
      updateProduct((current) => {
        applyCanonicalIds(current, response, sentPagesById);
        // Read before the variant reconcile below remaps the list: the
        // confirmed ids and the sent snapshot's scope keys share the
        // sent-era id namespace.
        const confirmedPageIdMappings = scopedConfirmedPageIdMappings(
          response,
          sentPagesById,
          current.confirmed_removed_variant_ids ?? [],
        );
        current.confirmed_removed_variant_ids = reconcileConfirmedRemovalIds(
          current.confirmed_removed_variant_ids ?? [],
          sentConfirmedVariantIds,
          response.variant_id_mappings,
        );
        current.confirmed_removed_rich_content_ids = reconcileConfirmedRemovalIds(
          current.confirmed_removed_rich_content_ids ?? [],
          sentConfirmedPageIds,
          confirmedPageIdMappings,
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
    const { confirmed, unexpected } = findPendingDeletions(product, lastSavedProductRef.current);
    // Content missing without recorded intent means the session lost state:
    // fail closed and ask for a reload instead of offering it as a deletion.
    if (unexpected.variants.length + unexpected.pages.length > 0) {
      setMissingContentConflict(unexpected);
      return Promise.resolve(false);
    }
    // A save that deletes existing versions/tiers or content pages gets one
    // final summary confirmation before the request goes out. Each deletion
    // already had its own modal when the seller clicked delete, but this is
    // the last chance to notice an accumulated (possibly large) wipe before
    // it becomes permanent.
    if (confirmed.variants.length + confirmed.pages.length > 0) {
      setPendingDeletions(confirmed);
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
        {missingContentConflict ? (
          <Modal
            open
            onClose={() => setMissingContentConflict(null)}
            title="Some content couldn't be loaded"
            footer={
              <>
                <Button onClick={() => setMissingContentConflict(null)}>Keep editing</Button>
                <Button color="accent" onClick={() => window.location.reload()}>
                  Reload page
                </Button>
              </>
            }
          >
            <div className="flex flex-col gap-4">
              <p>This editor session lost track of the following content, so saving could permanently delete it:</p>
              {missingContentConflict.variants.length > 0 ? (
                <ul className="list-disc pl-6">
                  {missingContentConflict.variants.map(({ id, name }) => (
                    <li key={id}>{name || "Untitled"}</li>
                  ))}
                </ul>
              ) : null}
              {missingContentConflict.pages.length > 0 ? (
                <ul className="list-disc pl-6">
                  {missingContentConflict.pages.map(({ id, title }) => (
                    <li key={id}>{titleWithFallback(title)}</li>
                  ))}
                </ul>
              ) : null}
              <p>Nothing was saved or deleted. Reload the page to keep editing with the full content.</p>
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
