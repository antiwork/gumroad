import { DeletionOperations, SaveContractCollection } from "$app/components/ProductEdit/state";

// Builds the explicit deletion operations for a save (gumroad-private#1379).
//
// ## Why this exists
//
// The editor save used to be a full snapshot: whatever the payload didn't
// mention was deleted. That made three different things indistinguishable —
// "the seller removed it", "this client didn't load it", and "the field was
// malformed and got dropped" — and the server had to guess which. It guessed
// wrong often enough to empty live products.
//
// Under the contract the server never infers. Removal is stated, or it doesn't
// happen. This function is where the editor states it.
//
// ## Where the ids come from
//
// Not from diffing. The editor already records every removal the seller
// confirms, at the moment they confirm it, in `confirmed_removed_*_ids` — the
// deletion modals push onto those lists. Re-deriving deletions by comparing the
// current state against the loaded state would reintroduce exactly the
// inference this contract removes: a page the client failed to load looks
// identical to a page the seller deleted.
//
// So: the seller's confirmed removals ARE the deletion operations. Anything
// else missing from the payload is, by definition, not a deletion.

// The seller's confirmed removals are the only input this needs. Taking a
// narrow parameter type rather than the whole Product keeps the contract honest
// (nothing else can influence what gets deleted) and lets tests construct real
// inputs instead of casting a stub.
//
// Files, public files and integrations are read from the editor's own removal
// state rather than from a parallel `confirmed_removed_*` list, because that IS
// where those removals are already recorded: a file the seller removed carries
// `status.type === "removed"`, and an integration they unchecked is simply
// false. Introducing a second source of truth for the same fact would let the
// two disagree.
export type DeletionSources = {
  confirmed_removed_variant_ids?: string[];
  confirmed_removed_rich_content_ids?: string[];
  files?: { id: string; status: { type: string } }[];
  public_files?: { id: string; status?: { type: string } }[];
  // Keyed by provider name. The VALUES are the integration objects the server
  // sends (or null when that provider is not connected) — deliberately NOT
  // booleans: this mirrors Product["integrations"], and typing it as a boolean
  // map let the unit tests pass `true`/`false` fixtures that no real payload
  // ever produces, hiding the difference from the type checker.
  integrations?: Record<string, unknown>;
  // What the integrations looked like when this editing session loaded, so an
  // integration that was ON and is now OFF can be told apart from one that was
  // never on. Without this the client cannot distinguish "seller unchecked it"
  // from "it was already off", and would ask to disconnect things that were
  // never connected.
  //
  // This one IS a boolean map: it is a server-issued connected/not-connected
  // snapshot (ProductPresenter#edit_props), not the integration records.
  loaded_integrations?: Record<string, boolean>;
  // Versions / tiers / durations, for their version-scoped integration
  // deletions. Only the fields this derivation reads are required, so callers
  // can pass the editor's richer Variant objects unchanged.
  variants?: {
    id: string;
    newlyAdded?: boolean;
    integrations?: Record<string, boolean>;
    loaded_integrations?: Record<string, boolean>;
  }[];
};

// `clear_all` is deliberately not derived either. An empty collection in state
// means "this session has none loaded", which is not the same as "the seller
// emptied it" — that distinction is the whole point. A caller that genuinely
// wants to empty a collection passes it here explicitly.
export const buildDeletionOperations = (
  product: DeletionSources,
  clearedCollections: SaveContractCollection[] = [],
): DeletionOperations => {
  const deletedIds: Partial<Record<SaveContractCollection, string[]>> = {};

  // Variants (versions / tiers / durations) the seller removed via the
  // confirmation modal in this session.
  const removedVariants = product.confirmed_removed_variant_ids ?? [];
  if (removedVariants.length > 0) deletedIds.variants = [...new Set(removedVariants)];

  // Content pages removed via the page-deletion modal.
  const removedPages = product.confirmed_removed_rich_content_ids ?? [];
  if (removedPages.length > 0) deletedIds.rich_content = [...new Set(removedPages)];

  // Product files the seller removed. Unsaved files (dropbox drops that were
  // never persisted) carry a synthetic `drop_` id and have no server row to
  // delete, so naming them would ask the server to remove something that does
  // not exist.
  const removedFiles = (product.files ?? [])
    .filter((file) => file.status.type === "removed" && !file.id.startsWith("drop_"))
    .map((file) => file.id);
  if (removedFiles.length > 0) deletedIds.files = [...new Set(removedFiles)];

  const removedPublicFiles = (product.public_files ?? [])
    .filter((file) => file.status?.type === "removed")
    .map((file) => file.id);
  if (removedPublicFiles.length > 0) deletedIds.public_files = [...new Set(removedPublicFiles)];

  // An integration counts as removed only if it was actually on when this
  // session loaded and the seller has since turned it off.
  const loadedIntegrations = product.loaded_integrations;
  if (loadedIntegrations) {
    const current = product.integrations ?? {};
    const disconnected = Object.keys(loadedIntegrations).filter((name) => loadedIntegrations[name] && !current[name]);
    if (disconnected.length > 0) deletedIds.integrations = [...new Set(disconnected)];
  }

  // Version/tier-level integrations. Same rule as the product-level one above,
  // applied per version: an integration counts as removed only if the version
  // had it on when this session's baseline was taken and the seller has since
  // switched it off. Scoping matters here — the same integration can stay
  // connected on a sibling version, so this cannot collapse into the flat
  // `integrations` list.
  const variantDeletedIds: Record<string, Partial<Record<SaveContractCollection, string[]>>> = {};
  for (const variant of product.variants ?? []) {
    // A version created in this session has no server row to delete from, and
    // its id is a client-side counter rather than an external id.
    if (variant.newlyAdded) continue;

    const loadedForVariant = variant.loaded_integrations;
    if (!loadedForVariant) continue;

    const currentForVariant = variant.integrations ?? {};
    const turnedOff = Object.keys(loadedForVariant).filter(
      (name) => loadedForVariant[name] && !currentForVariant[name],
    );
    if (turnedOff.length > 0) variantDeletedIds[variant.id] = { integrations: [...new Set(turnedOff)] };
  }

  const operations: DeletionOperations = {
    deleted_ids: deletedIds,
    cleared_collections: [...new Set(clearedCollections)],
  };
  if (Object.keys(variantDeletedIds).length > 0) operations.variant_deleted_ids = variantDeletedIds;
  return operations;
};

// True when this save asks the server to remove anything at all. Used to decide
// whether the revision token is required: a save that deletes nothing does not
// need to prove which snapshot it came from, so a stale tab can still fix a
// typo without being told to reload.
//
// The Array.isArray check is not just a type narrowing: `deleted_ids` is a
// Partial record, so a caller can legitimately hand us a key whose value is
// undefined, and reading `.length` off that would throw during a save.
export const hasDeletions = (operations: DeletionOperations): boolean =>
  operations.cleared_collections.length > 0 ||
  Object.values(operations.deleted_ids).some((ids: unknown) => Array.isArray(ids) && ids.length > 0) ||
  // Version-scoped removals are deletions too. Omitting them here would let a
  // save whose ONLY deletion is "disconnect Discord from this tier" travel
  // without a revision token, which is precisely the stale-tab case the token
  // exists to catch.
  Object.values(operations.variant_deleted_ids ?? {}).some((collections) =>
    Object.values(collections).some((ids: unknown) => Array.isArray(ids) && ids.length > 0),
  );
