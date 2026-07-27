import {
  DeletionOperations,
  Product,
  SaveContractCollection,
} from "$app/components/ProductEdit/state";

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

// `clear_all` is deliberately not derived either. An empty collection in state
// means "this session has none loaded", which is not the same as "the seller
// emptied it" — that distinction is the whole point. A caller that genuinely
// wants to empty a collection passes it here explicitly.
export const buildDeletionOperations = (
  product: Product,
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

  return {
    deleted_ids: deletedIds,
    cleared_collections: [...new Set(clearedCollections)],
  };
};

// True when this save asks the server to remove anything at all. Used to decide
// whether the revision token is required: a save that deletes nothing does not
// need to prove which snapshot it came from, so a stale tab can still fix a
// typo without being told to reload.
export const hasDeletions = (operations: DeletionOperations): boolean =>
  operations.cleared_collections.length > 0 ||
  Object.values(operations.deleted_ids).some((ids) => (ids?.length ?? 0) > 0);
