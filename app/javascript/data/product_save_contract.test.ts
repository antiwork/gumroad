import { describe, expect, it } from "vitest";

import { DeletionSources, buildDeletionOperations, hasDeletions } from "$app/data/product_save_contract";

// The editor's save used to delete whatever the payload didn't mention. Under
// the save contract (gumroad-private#1379) it can only delete what it names, so
// these tests are really about one question: can this function ever produce a
// deletion the seller did not ask for?
//
// buildDeletionOperations takes only the seller's confirmed-removal lists, not
// a whole Product, so these are real inputs rather than casts of a stub — if
// the contract ever started reading something else to decide what to delete,
// this would stop compiling, which is the point.
const productWith = (fields: DeletionSources): DeletionSources => fields;

describe("buildDeletionOperations", () => {
  it("asks for no deletions when the seller removed nothing", () => {
    const operations = buildDeletionOperations(productWith({}));

    expect(operations.deleted_ids).toEqual({});
    expect(operations.cleared_collections).toEqual([]);
    expect(hasDeletions(operations)).toBe(false);
  });

  // The important one. An editor session that loaded no variants looks
  // identical, in state, to a session where the seller deleted them all — which
  // is exactly the ambiguity that emptied live products. Empty state must
  // therefore mean "nothing to delete", never "delete everything".
  // The important one. An editor session that loaded no variants looks
  // identical, in state, to a session where the seller deleted them all — which
  // is exactly the ambiguity that emptied live products. The builder cannot even
  // see the collections (its parameter type only carries the confirmed-removal
  // lists), so an empty editor state has no route to becoming a deletion.
  it("asks for no deletions when the seller confirmed none, whatever the collections hold", () => {
    const operations = buildDeletionOperations(
      productWith({ confirmed_removed_variant_ids: [], confirmed_removed_rich_content_ids: [] }),
    );

    expect(operations.deleted_ids).toEqual({});
    expect(operations.cleared_collections).toEqual([]);
    expect(hasDeletions(operations)).toBe(false);
  });

  it("names exactly the variants the seller confirmed removing", () => {
    const operations = buildDeletionOperations(
      productWith({ confirmed_removed_variant_ids: ["variant-a", "variant-b"] }),
    );

    expect(operations.deleted_ids.variants).toEqual(["variant-a", "variant-b"]);
    expect(operations.deleted_ids.rich_content).toBeUndefined();
    expect(hasDeletions(operations)).toBe(true);
  });

  it("names exactly the content pages the seller confirmed removing", () => {
    const operations = buildDeletionOperations(productWith({ confirmed_removed_rich_content_ids: ["page-1"] }));

    expect(operations.deleted_ids.rich_content).toEqual(["page-1"]);
    expect(operations.deleted_ids.variants).toBeUndefined();
  });

  // A seller can hit remove on the same record twice in one session (remove,
  // undo, remove). Sending the id twice is harmless server-side but makes the
  // audit record misleading about how many things were deleted.
  it("does not repeat an id the seller confirmed twice", () => {
    const operations = buildDeletionOperations(
      productWith({ confirmed_removed_variant_ids: ["variant-a", "variant-a", "variant-b"] }),
    );

    expect(operations.deleted_ids.variants).toEqual(["variant-a", "variant-b"]);
  });

  // Clearing a whole collection is never inferred: the caller has to pass it,
  // because "this session holds none" and "the seller emptied it" are different
  // statements and only the second one authorises deletion.
  it("only clears a collection when explicitly told to", () => {
    const withoutClear = buildDeletionOperations(productWith({ confirmed_removed_variant_ids: [] }));
    expect(withoutClear.cleared_collections).toEqual([]);

    const withClear = buildDeletionOperations(productWith({}), ["variants"]);
    expect(withClear.cleared_collections).toEqual(["variants"]);
    expect(hasDeletions(withClear)).toBe(true);
  });

  it("does not repeat a collection named twice for clearing", () => {
    const operations = buildDeletionOperations(productWith({}), ["variants", "variants", "files"]);

    expect(operations.cleared_collections).toEqual(["variants", "files"]);
  });
});

describe("hasDeletions", () => {
  it("is false for empty operations", () => {
    expect(hasDeletions({ deleted_ids: {}, cleared_collections: [] })).toBe(false);
  });

  // A collection key present but empty is not a deletion request. Treating it
  // as one would resurrect the "[] means delete everything" behaviour on the
  // client side.
  it("is false when a collection key is present but empty", () => {
    expect(hasDeletions({ deleted_ids: { variants: [] }, cleared_collections: [] })).toBe(false);
  });

  it("is true when any id is named", () => {
    expect(hasDeletions({ deleted_ids: { files: ["f1"] }, cleared_collections: [] })).toBe(true);
  });

  it("is true when any collection is cleared", () => {
    expect(hasDeletions({ deleted_ids: {}, cleared_collections: ["integrations"] })).toBe(true);
  });
});
