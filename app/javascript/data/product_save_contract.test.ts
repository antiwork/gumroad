import { describe, expect, it } from "vitest";

import {
  DeletionSources,
  buildDeletionOperations,
  confirmRemovedVariantPageDeletions,
  hasDeletions,
  reorderPreservingMembership,
  reorderRowsPreservingMembership,
} from "$app/data/product_save_contract";

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

  it("records a removed variant's pages and their move sources", () => {
    const product = productWith({ confirmed_removed_rich_content_ids: ["already-confirmed"] });

    confirmRemovedVariantPageDeletions(
      product,
      [
        { id: "stored-page", move_source_id: "shared-source" },
        { id: "stored-page-2", move_source_id: "shared-source" },
        // An unsaved page's client id is recorded too: inert server-side, and
        // remapped to the canonical id if an in-flight save creates the row.
        { id: "unsaved-page" },
      ],
      new Set(),
    );

    expect(product.confirmed_removed_rich_content_ids).toEqual([
      "already-confirmed",
      "stored-page",
      "shared-source",
      "stored-page-2",
      "unsaved-page",
    ]);
    expect(buildDeletionOperations(product).deleted_ids.rich_content).toEqual([
      "already-confirmed",
      "stored-page",
      "shared-source",
      "stored-page-2",
      "unsaved-page",
    ]);
  });

  // Raw ids can repeat across scopes; a stored id a surviving page still
  // carries must not become deletion intent against the survivor's row. A
  // newly added page's client id records regardless: it is inert until
  // reconciliation resolves it, and ambiguous resolutions are dropped.
  it("skips a removed stored page's id when a surviving page still carries it", () => {
    const product = productWith({});

    confirmRemovedVariantPageDeletions(
      product,
      [
        { id: "shared-stored-id" },
        { id: "only-here", move_source_id: "kept-source" },
        { id: "shared-new-id", newlyAdded: true },
      ],
      new Set(["shared-stored-id", "kept-source", "shared-new-id"]),
    );

    expect(product.confirmed_removed_rich_content_ids).toEqual(["only-here", "shared-new-id"]);
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

  // Files, public files and integrations: the three collections the client
  // could previously only delete by omission.
  describe("files", () => {
    it("names exactly the files the seller removed", () => {
      const operations = buildDeletionOperations(
        productWith({
          files: [
            { id: "f1", status: { type: "removed" } },
            { id: "f2", status: { type: "saved" } },
          ],
        }),
      );

      expect(operations.deleted_ids.files).toEqual(["f1"]);
    });

    // A file the seller dropped in and then removed in the same session was
    // never persisted, so there is no server row to delete. Naming it would ask
    // the server to remove something that does not exist.
    it("ignores unsaved dropbox files that were removed before saving", () => {
      const operations = buildDeletionOperations(
        productWith({ files: [{ id: "drop_abc", status: { type: "removed" } }] }),
      );

      expect(operations.deleted_ids.files).toBeUndefined();
      expect(hasDeletions(operations)).toBe(false);
    });

    it("asks for nothing when the seller removed no files", () => {
      const operations = buildDeletionOperations(productWith({ files: [{ id: "f1", status: { type: "saved" } }] }));

      expect(operations.deleted_ids.files).toBeUndefined();
    });
  });

  describe("public files", () => {
    it("names exactly the public files the seller removed", () => {
      const operations = buildDeletionOperations(
        productWith({
          public_files: [
            { id: "p1", status: { type: "removed" } },
            { id: "p2", status: { type: "saved" } },
            { id: "p3" },
          ],
        }),
      );

      expect(operations.deleted_ids.public_files).toEqual(["p1"]);
    });
  });

  describe("integrations", () => {
    // The real payload shape: Product["integrations"] holds the integration
    // RECORD (or null when disconnected), never a boolean. The earlier fixtures
    // here used booleans, which typechecked against a wrong local type and hid
    // the difference — these use the shape the server actually sends.
    const connected = (name: string) => ({ name, keep_inactive_members: false, integration_details: {} });

    it("names an integration that was connected and the seller turned off", () => {
      const operations = buildDeletionOperations(
        productWith({
          loaded_integrations: { circle: true, discord: true },
          integrations: { circle: null, discord: connected("discord") },
        }),
      );

      expect(operations.deleted_ids.integrations).toEqual(["circle"]);
    });

    // The reason the server issues a loaded_integrations baseline at all: an
    // integration that is off now and was off then is not a removal, and
    // disconnecting is irreversible.
    it("does not name an integration that was already off", () => {
      const operations = buildDeletionOperations(
        productWith({ loaded_integrations: { circle: false }, integrations: { circle: null } }),
      );

      expect(operations.deleted_ids.integrations).toBeUndefined();
      expect(hasDeletions(operations)).toBe(false);
    });

    it("does not name an integration the seller just turned on", () => {
      const operations = buildDeletionOperations(
        productWith({ loaded_integrations: { circle: false }, integrations: { circle: connected("circle") } }),
      );

      expect(operations.deleted_ids.integrations).toBeUndefined();
    });

    // Incomplete state must never become deletion intent. `loaded[name] &&
    // !current[name]` used to answer "removed" here, because a missing map or a
    // missing key reads as `undefined` and `!undefined` is true — the contract's
    // own omission-inference bug, relocated to the client. The live map and the
    // provider key both have to be present before anything counts as removed.
    it("asks for no disconnections when the live integrations map is absent", () => {
      const operations = buildDeletionOperations(productWith({ loaded_integrations: { circle: true, discord: true } }));

      expect(operations.deleted_ids.integrations).toBeUndefined();
      expect(hasDeletions(operations)).toBe(false);
    });

    it("asks for no disconnections for a provider key absent from the live map", () => {
      const operations = buildDeletionOperations(
        productWith({
          loaded_integrations: { circle: true, discord: true },
          // `discord` was connected at baseline but this payload says nothing
          // about it. Silence is not a disconnect request.
          integrations: { circle: connected("circle") },
        }),
      );

      expect(operations.deleted_ids.integrations).toBeUndefined();
      expect(hasDeletions(operations)).toBe(false);
    });

    // Only an explicit `null` — the shape the server uses for "not connected" —
    // counts. An `undefined` value is absence, not a disconnection.
    it("names only providers explicitly reported as disconnected", () => {
      const operations = buildDeletionOperations(
        productWith({
          loaded_integrations: { circle: true, discord: true },
          integrations: { circle: null, discord: undefined },
        }),
      );

      expect(operations.deleted_ids.integrations).toEqual(["circle"]);
    });

    // Without a baseline the client cannot tell removal from never-connected,
    // so it must not guess — the safe answer is to ask for no disconnections.
    it("asks for no disconnections when the server sent no baseline", () => {
      const operations = buildDeletionOperations(productWith({ integrations: { circle: null } }));

      expect(operations.deleted_ids.integrations).toBeUndefined();
      expect(hasDeletions(operations)).toBe(false);
    });

    // gumroad-private#1379: connect -> save -> disconnect -> save, no reload.
    //
    // The baseline is issued at page load, when circle was NOT connected. The
    // first save connects it. If the editor keeps the load-time baseline, the
    // second save compares "was off at load" against "off now" and emits no
    // deletion — the integration silently survives a disconnect the seller
    // explicitly performed. The fix is for the save response to carry a
    // refreshed baseline that the editor adopts (applyCanonicalIds).
    it("names an integration connected and then disconnected in the same session", () => {
      // Page load: circle is off.
      const product = productWith({
        loaded_integrations: { circle: false },
        integrations: { circle: connected("circle") },
      });
      // Save #1 connects it, and the server answers with the refreshed
      // baseline for the state it just committed.
      product.loaded_integrations = { circle: true };
      // The seller now turns it off and saves again, without reloading.
      product.integrations = { circle: null };

      const operations = buildDeletionOperations(product);

      expect(operations.deleted_ids.integrations).toEqual(["circle"]);
    });

    // The same sequence with the STALE baseline, i.e. the bug. Kept as an
    // explicit statement of what must not happen.
    it("misses the disconnect if the baseline is never refreshed", () => {
      const stale = productWith({
        loaded_integrations: { circle: false }, // never updated after save #1
        integrations: { circle: null },
      });

      expect(buildDeletionOperations(stale).deleted_ids.integrations).toBeUndefined();
    });
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

  // A save whose only deletion is version-scoped still has to carry the
  // revision token, or the stale-tab guard never runs for it.
  it("is true when only a version-scoped deletion is named", () => {
    expect(
      hasDeletions({
        deleted_ids: {},
        cleared_collections: [],
        variant_deleted_ids: { v1: { integrations: ["discord"] } },
      }),
    ).toBe(true);
  });

  it("is false when a version-scoped entry is present but empty", () => {
    expect(
      hasDeletions({ deleted_ids: {}, cleared_collections: [], variant_deleted_ids: { v1: { integrations: [] } } }),
    ).toBe(false);
  });
});

// The version/tier equivalent of the product-level integrations rules. The
// editor could not express these at all before: `variant_deleted_ids` existed
// server-side, but nothing in the client emitted it, so unchecking a version's
// Discord switch returned success and left the integration connected.
describe("buildDeletionOperations, version-scoped integrations", () => {
  const variant = (fields: Partial<NonNullable<DeletionSources["variants"]>[number]> = {}) => ({
    id: "v1",
    integrations: { discord: false },
    loaded_integrations: { discord: true },
    ...fields,
  });

  it("names an integration a version had on and the seller switched off", () => {
    const operations = buildDeletionOperations(productWith({ variants: [variant()] }));

    expect(operations.variant_deleted_ids).toEqual({ v1: { integrations: ["discord"] } });
  });

  it("scopes the removal to that version, leaving a sibling with the same integration alone", () => {
    const operations = buildDeletionOperations(
      productWith({
        variants: [
          variant(),
          variant({ id: "v2", integrations: { discord: true }, loaded_integrations: { discord: true } }),
        ],
      }),
    );

    expect(operations.variant_deleted_ids).toEqual({ v1: { integrations: ["discord"] } });
  });

  it("asks for nothing when a version's integration is untouched", () => {
    const operations = buildDeletionOperations(
      productWith({ variants: [variant({ integrations: { discord: true } })] }),
    );

    expect(operations.variant_deleted_ids).toBeUndefined();
  });

  // The version-scoped mirror of the product-level baseline rule: an
  // integration that was never on cannot be "removed" by being off.
  it("asks for nothing when the integration was already off at the baseline", () => {
    const operations = buildDeletionOperations(
      productWith({ variants: [variant({ loaded_integrations: { discord: false } })] }),
    );

    expect(operations.variant_deleted_ids).toBeUndefined();
  });

  // Without a baseline the client cannot tell "switched off" from "never on",
  // so it must not guess — same rule as the product level.
  it("asks for nothing when the version has no baseline", () => {
    const operations = buildDeletionOperations(
      productWith({ variants: [{ id: "v1", integrations: { discord: false } }] }),
    );

    expect(operations.variant_deleted_ids).toBeUndefined();
  });

  // The version-level twin of the product-level incomplete-state rule. A
  // version whose payload carries no integrations map, or omits a provider that
  // was connected at baseline, has said nothing — and silence is not a request
  // to disconnect.
  it("asks for nothing when the version's live integrations map is absent", () => {
    const operations = buildDeletionOperations(
      productWith({ variants: [{ id: "v1", loaded_integrations: { discord: true, circle: true } }] }),
    );

    expect(operations.variant_deleted_ids).toBeUndefined();
    expect(hasDeletions(operations)).toBe(false);
  });

  it("asks for nothing for a provider key absent from the version's live map", () => {
    const operations = buildDeletionOperations(
      productWith({
        variants: [
          {
            id: "v1",
            loaded_integrations: { discord: true, circle: true },
            // `discord` was on at baseline but this payload never mentions it.
            integrations: { circle: true },
          },
        ],
      }),
    );

    expect(operations.variant_deleted_ids).toBeUndefined();
    expect(hasDeletions(operations)).toBe(false);
  });

  // Version-level values are booleans, so `false` is the disconnect signal and
  // `undefined` is absence.
  it("names only versions' providers explicitly switched off", () => {
    const operations = buildDeletionOperations(
      productWith({
        variants: [
          {
            id: "v1",
            loaded_integrations: { discord: true, circle: true },
            integrations: { discord: false, circle: undefined },
          },
        ],
      }),
    );

    expect(operations.variant_deleted_ids).toEqual({ v1: { integrations: ["discord"] } });
  });

  // A version created in this session has no server row to delete from, and its
  // id is a client-side counter the server would not recognise.
  it("ignores a version created in this session", () => {
    const operations = buildDeletionOperations(productWith({ variants: [variant({ newlyAdded: true })] }));

    expect(operations.variant_deleted_ids).toBeUndefined();
  });

  // connect -> save -> disconnect -> save, without reloading. The second save
  // only emits the deletion because the first save's response refreshed this
  // version's baseline (applyCanonicalIds); with a stale baseline the
  // integration was recorded as "never on" and silently survived.
  it("names the removal after a same-session enable, once the baseline is refreshed", () => {
    const beforeRefresh = buildDeletionOperations(
      productWith({
        variants: [variant({ integrations: { discord: false }, loaded_integrations: { discord: false } })],
      }),
    );
    expect(beforeRefresh.variant_deleted_ids).toBeUndefined();

    // The save that connected it returns variant_loaded_integrations; the
    // editor adopts that as the version's new baseline.
    const afterRefresh = buildDeletionOperations(
      productWith({
        variants: [variant({ integrations: { discord: false }, loaded_integrations: { discord: true } })],
      }),
    );
    expect(afterRefresh.variant_deleted_ids).toEqual({ v1: { integrations: ["discord"] } });
  });
});

// The reported failure in gumroad-private#1508: a save that returned 200 and
// deleted nothing. Under the contract the only payload that produces it is one
// whose deletion operations name nothing, so a row leaving state without a
// confirmed-removal id is the client-side defect. Reorder was that route.
describe("reorderPreservingMembership", () => {
  const rows = [{ id: "a" }, { id: "b" }, { id: "c" }];

  it("applies the order it was given", () => {
    expect(reorderPreservingMembership(rows, ["c", "a", "b"])).toEqual([{ id: "c" }, { id: "a" }, { id: "b" }]);
  });

  it("keeps a row the order omitted instead of dropping it", () => {
    expect(reorderPreservingMembership(rows, ["c", "a"])).toEqual([{ id: "c" }, { id: "a" }, { id: "b" }]);
  });

  it("keeps every row when the order is empty", () => {
    expect(reorderPreservingMembership(rows, [])).toEqual(rows);
  });

  it("ignores ids that are not in the list and never duplicates one", () => {
    expect(reorderPreservingMembership(rows, ["b", "ghost", "b", "a", "c"])).toEqual([
      { id: "b" },
      { id: "a" },
      { id: "c" },
    ]);
  });

  // Unreachable today (external ids are unique), but a helper whose name
  // promises membership must not quietly drop a twin if that ever changes.
  it("keeps both rows when two share an id", () => {
    const twins = [
      { id: "a", n: 1 },
      { id: "a", n: 2 },
      { id: "b", n: 3 },
    ];

    expect(reorderPreservingMembership(twins, ["b", "a"])).toEqual([
      { id: "b", n: 3 },
      { id: "a", n: 1 },
      { id: "a", n: 2 },
    ]);
  });
});

// The content-tab page sortable reports its new order as the row objects, not
// ids, and the library annotates those objects (a page's `chosen` drag flag is
// read off them) — so they are kept rather than looked up again.
describe("reorderRowsPreservingMembership", () => {
  const all = [{ id: "p1" }, { id: "p2" }, { id: "p3" }];

  it("applies the reported order", () => {
    expect(reorderRowsPreservingMembership([{ id: "p3" }, { id: "p1" }, { id: "p2" }], all)).toEqual([
      { id: "p3" },
      { id: "p1" },
      { id: "p2" },
    ]);
  });

  it("keeps a page the report omitted instead of dropping it", () => {
    expect(reorderRowsPreservingMembership([{ id: "p3" }, { id: "p1" }], all)).toEqual([
      { id: "p3" },
      { id: "p1" },
      { id: "p2" },
    ]);
  });

  it("keeps every page when the report is empty", () => {
    expect(reorderRowsPreservingMembership([], all)).toEqual(all);
  });

  it("keeps the reported objects, not the originals", () => {
    const annotated = { id: "p1", chosen: true };
    const result = reorderRowsPreservingMembership([annotated], all);

    expect(result[0]).toBe(annotated);
    expect(result).toHaveLength(3);
  });

  it("drops a page the product never had instead of adding it", () => {
    expect(reorderRowsPreservingMembership([{ id: "ghost" }, { id: "p2" }], all)).toEqual([
      { id: "p2" },
      { id: "p1" },
      { id: "p3" },
    ]);
  });

  it("emits a repeated id once", () => {
    expect(reorderRowsPreservingMembership([{ id: "p2" }, { id: "p2" }, { id: "p1" }], all)).toEqual([
      { id: "p2" },
      { id: "p1" },
      { id: "p3" },
    ]);
  });
});
