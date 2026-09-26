import { history, undo } from "@tiptap/pm/history";
import { Schema } from "@tiptap/pm/model";
import { EditorState, TextSelection } from "@tiptap/pm/state";
import { describe, expect, it, vi } from "vitest";

import {
  applyFileIdMappingsToRichContent,
  applyRichContentPageSaveResponse,
  buildRichContentFileIdMappingTransaction,
  buildRichContentReconciliationTransaction,
  HiddenVariantContentConflictError,
  canonicalRichContentScope,
  copyRichContentPages,
  filesForSave,
  prepareRichContentPagesForMove,
  reconcileConfirmedRemovalIds,
  removeFileEmbedsFromRichContent,
  removedFileEmbedIdsForPage,
  resolveServerIdMapping,
  richContentMoveSourceIds,
  saveProduct,
  saveProductError,
  scalarSettingsForSave,
  StaleContentConflictError,
  StaleDeletionConflictError,
  UnmarkedInstallmentPlanClearConflictError,
} from "$app/data/product_edit";
import { ResponseError } from "$app/utils/request";

vi.mock("@tiptap/core", () => ({
  Editor: class {
    schema = { nodeFromJSON: () => ({}) };
    destroy() {}
  },
  findChildren: () => [],
}));
vi.mock("$app/components/ProductEdit/ContentTab", () => ({ extensions: () => [] }));
vi.mock("$app/components/ProductEdit/ContentTab/FileEmbed", () => ({ FileEmbed: { name: "fileEmbed" } }));
vi.mock("$app/components/RichTextEditor", () => ({ baseEditorOptions: () => ({}) }));

describe("filesForSave", () => {
  it("does not remove files from editor state before a hidden-content conflict retry", () => {
    const file = { id: "file-id" };
    const editorFiles = [file];

    expect(filesForSave(editorFiles, new Set(), false)).toEqual([]);
    expect(editorFiles).toEqual([file]);
    expect(filesForSave(editorFiles, new Set(), true)).toEqual([file]);
  });

  it("drops a file whose upload failed, on both the embedded-only and keep-all paths", () => {
    const uploaded = { id: "uploaded-id" };
    const failed = { id: "failed-id", status: { type: "unsaved", uploadStatus: { type: "failed" } } };
    const editorFiles = [uploaded, failed];

    expect(filesForSave(editorFiles, new Set(["uploaded-id", "failed-id"]), false)).toEqual([uploaded]);
    expect(filesForSave(editorFiles, new Set(), true)).toEqual([uploaded]);
  });
});

const requestMock = vi.hoisted(() => vi.fn());
vi.mock("$app/utils/request", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/utils/request")>()),
  request: requestMock,
}));

describe("saveProduct with a failed upload", () => {
  const failedId = "failed-file";
  const productWithFailedEmbed = () => ({
    files: [
      { id: "saved-file", status: { type: "saved" } },
      { id: failedId, status: { type: "unsaved", uploadStatus: { type: "failed" } } },
    ],
    public_files: [],
    rich_content: [
      {
        id: "page-1",
        title: "Page",
        description: {
          type: "doc",
          content: [
            { type: "fileEmbed", attrs: { id: failedId, uid: "uid-1" } },
            { type: "fileEmbed", attrs: { id: "saved-file", uid: "uid-2" } },
          ],
        },
      },
    ],
    variants: [],
    has_same_rich_content_for_all_variants: true,
    covers: [],
    availabilities: [],
    confirmed_removed_variant_ids: [],
    confirmed_removed_rich_content_ids: [],
    preserved_rich_content_ids: [],
    editor_revision: null,
    allow_installment_plan: false,
  });

  it("saves neither the failed file nor the embed it left in the content", async () => {
    // Rails injects this global; the save URL goes through it.
    Object.assign(globalThis, { Routes: { link_path: () => "/p/demo" } });
    requestMock.mockReset().mockResolvedValue({ ok: true, status: 204 });
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture only carries the fields the save reads
    const product = productWithFailedEmbed() as unknown as Parameters<typeof saveProduct>[2];

    await saveProduct("demo", "product-id", product, "usd", { keepAllFiles: true });

    expect(requestMock).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          files: [{ id: "saved-file", status: { type: "saved" } }],
          rich_content: [
            {
              id: "page-1",
              title: "Page",
              description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: "saved-file", uid: "uid-2" } }] },
            },
          ],
        }),
      }),
    );
  });
});

describe("scalarSettingsForSave", () => {
  const product = (overrides = {}) => ({
    custom_permalink: null,
    description: "",
    customizable_price: false,
    price_cents: 100,
    hasPaidVariantPricing: false,
    installment_plan: null,
    allow_installment_plan: false,
    ...overrides,
  });
  const lastSaved = (overrides = {}) => ({
    custom_permalink: null,
    description: null,
    customizable_price: false,
    price_cents: 100,
    hasPaidVariantPricing: false,
    installment_plan: null,
    allow_installment_plan: false,
    ...overrides,
  });

  it("omits an unchanged blank custom permalink so a stale tab cannot clear it", () => {
    expect(scalarSettingsForSave(product(), lastSaved())).toEqual({});
    expect(scalarSettingsForSave(product({ custom_permalink: "" }), lastSaved())).toEqual({});
  });

  it("sends a marker when this session clears an existing custom permalink", () => {
    expect(scalarSettingsForSave(product(), lastSaved({ custom_permalink: "kept-slug" }))).toEqual({
      custom_permalink: null,
      custom_permalink_changed: true,
    });
  });

  it("sends a non-empty custom permalink", () => {
    expect(scalarSettingsForSave(product({ custom_permalink: "my-custom-url" }), lastSaved())).toEqual({
      custom_permalink: "my-custom-url",
    });
  });

  it("omits an unchanged customizable_price when every driving input is unchanged", () => {
    // A stale tab whose price, variant structure, and PWYW flag all match the
    // last-saved state must not turn PWYW off on an unrelated section save.
    expect(
      scalarSettingsForSave(product({ customizable_price: true }), lastSaved({ customizable_price: true })),
    ).toEqual({});
  });

  it("sends the recomputed customizable_price when the price changed, even if the flag looks unchanged", () => {
    // The $0-base + paid-variant force re-derives the flag from price/variants.
    // A save that sets Amount to 0 MUST send the recomputed false, not omit it
    // (this is the failing edit_spec force case).
    expect(
      scalarSettingsForSave(
        product({ customizable_price: false, price_cents: 0, hasPaidVariantPricing: true }),
        lastSaved({ customizable_price: false, hasPaidVariantPricing: true }),
      ),
    ).toEqual({ customizable_price: false });
  });

  it("sends a customizable_price change this session made, in both directions", () => {
    expect(scalarSettingsForSave(product({ customizable_price: true }), lastSaved())).toEqual({
      customizable_price: true,
    });
    // Deliberate disabling must still send false — a truthiness-based refactor
    // that drops `false` would silently leave PWYW enabled.
    expect(
      scalarSettingsForSave(product({ customizable_price: false }), lastSaved({ customizable_price: true })),
    ).toEqual({ customizable_price: false });
  });

  it("omits a blank description unless this session edited the field", () => {
    expect(scalarSettingsForSave(product({ description: "" }), lastSaved())).toEqual({});
    expect(scalarSettingsForSave(product({ description: "", description_changed: true }), lastSaved())).toEqual({
      description: null,
      description_changed: true,
    });
    expect(scalarSettingsForSave(product({ description: "", description_changed: false }), lastSaved())).toEqual({});
  });

  it("sends a non-empty description", () => {
    expect(scalarSettingsForSave(product({ description: "<p>Hi</p>" }), lastSaved())).toEqual({
      description: "<p>Hi</p>",
    });
  });

  it("omits a description unchanged from the last-saved one", () => {
    // Two editor instances can hold divergent copies of this field. The one
    // whose copy still matches what it last saved must not re-post it, or an
    // unrelated save reverts the copy the other instance already stored.
    expect(
      scalarSettingsForSave(product({ description: "<p>Hi</p>" }), lastSaved({ description: "<p>Hi</p>" })),
    ).toEqual({});
    expect(
      scalarSettingsForSave(
        product({ description: "<p>Hi</p>", description_changed: true }),
        lastSaved({ description: "<p>Hi</p>" }),
      ),
    ).toEqual({});
  });

  it("sends a description that differs from the last-saved one", () => {
    expect(
      scalarSettingsForSave(product({ description: "<p>New</p>" }), lastSaved({ description: "<p>Old</p>" })),
    ).toEqual({ description: "<p>New</p>" });
    // A seller who empties the field and retypes is a change in both directions.
    expect(
      scalarSettingsForSave(product({ description: "<p>Old</p>" }), lastSaved({ description: "<p>New</p>" })),
    ).toEqual({ description: "<p>Old</p>" });
    // A caller that does not track a baseline keeps the always-submit behavior.
    expect(
      scalarSettingsForSave(product({ description: "<p>Hi</p>" }), lastSaved({ description: undefined })),
    ).toEqual({ description: "<p>Hi</p>" });
  });

  it("treats the editor's empty document as blank", () => {
    // An emptied rich-text editor serializes to markup, so truthiness alone
    // would let an unmarked stale snapshot overwrite newer copy with it.
    expect(scalarSettingsForSave(product({ description: "<p><br></p>" }), lastSaved())).toEqual({});
    expect(scalarSettingsForSave(product({ description: "<p>&nbsp;</p>" }), lastSaved())).toEqual({});
    expect(scalarSettingsForSave(product({ description: "<ul><li><p><br></p></li></ul>" }), lastSaved())).toEqual({});
    expect(scalarSettingsForSave(product({ description: "<h2></h2>" }), lastSaved())).toEqual({});
  });

  it("still sends a description that renders something, embed-only included", () => {
    expect(scalarSettingsForSave(product({ description: "<img src='x.png'>" }), lastSaved())).toEqual({
      description: "<img src='x.png'>",
    });
    expect(scalarSettingsForSave(product({ description: "<figure><audio></audio></figure>" }), lastSaved())).toEqual({
      description: "<figure><audio></audio></figure>",
    });
    expect(scalarSettingsForSave(product({ description: "<p> <br> hi </p>" }), lastSaved())).toEqual({
      description: "<p> <br> hi </p>",
    });
    // The media node serializes as an attribute-only wrapper — the payload is in
    // the attributes, so it is content even with nothing between the tags. A
    // session that edited the field would otherwise send a clear and drop it.
    const mediaEmbed =
      '<div class="tiptap__raw" data-url="https://example.com/x.mp4" data-thumbnail="https://example.com/x.png"></div>';
    expect(scalarSettingsForSave(product({ description: mediaEmbed }), lastSaved())).toEqual({
      description: mediaEmbed,
    });
    expect(scalarSettingsForSave(product({ description: mediaEmbed, description_changed: true }), lastSaved())).toEqual(
      { description: mediaEmbed },
    );
  });

  it("clears when the session emptied the editor", () => {
    expect(
      scalarSettingsForSave(product({ description: "<p><br></p>", description_changed: true }), lastSaved()),
    ).toEqual({ description: null, description_changed: true });
  });

  it("always sends customizable_price when the caller has no baseline", () => {
    // A caller that does not track the last-saved value (null baseline) must
    // keep the pre-fix always-submit behavior, so disabling PWYW still lands.
    expect(
      scalarSettingsForSave(product({ customizable_price: false }), { ...lastSaved(), customizable_price: null }),
    ).toEqual({ customizable_price: false });
  });

  it("omits an unchanged installment plan so a stale tab cannot delete the seller's plan", () => {
    expect(scalarSettingsForSave(product(), lastSaved())).toEqual({});
  });

  it("sends the plan when this session turned the toggle on", () => {
    expect(
      scalarSettingsForSave(
        product({ allow_installment_plan: true, installment_plan: { number_of_installments: 2 } }),
        lastSaved(),
      ),
    ).toEqual({ installment_plan: { number_of_installments: 2 } });
  });

  it("sends the plan when this session changed the installment count", () => {
    expect(
      scalarSettingsForSave(
        product({ allow_installment_plan: true, installment_plan: { number_of_installments: 4 } }),
        lastSaved({ allow_installment_plan: true, installment_plan: { number_of_installments: 2 } }),
      ),
    ).toEqual({ installment_plan: { number_of_installments: 4 } });
  });

  it("marks a deliberate toggle-off as a clear so the server can tell it from a stale tab", () => {
    expect(
      scalarSettingsForSave(
        product({ allow_installment_plan: false, installment_plan: null }),
        lastSaved({ allow_installment_plan: true, installment_plan: { number_of_installments: 2 } }),
      ),
    ).toEqual({ installment_plan: null, installment_plan_changed: true });
  });

  it("always sends installment_plan when the caller has no baseline", () => {
    expect(
      scalarSettingsForSave(
        product({ allow_installment_plan: true, installment_plan: { number_of_installments: 2 } }),
        { ...lastSaved(), allow_installment_plan: null },
      ),
    ).toEqual({ installment_plan: { number_of_installments: 2 } });
    expect(
      scalarSettingsForSave(product({ allow_installment_plan: false }), {
        ...lastSaved(),
        allow_installment_plan: null,
      }),
    ).toEqual({ installment_plan: null, installment_plan_changed: true });
  });
});

describe("copyRichContentPages", () => {
  it("keeps stored source ids while assigning new page ids and clearing copied upsell ids", () => {
    const sourcePage = {
      id: "source-page",
      title: "Source",
      updated_at: "2026-07-28T00:00:00.000Z",
      description: {
        type: "doc",
        content: [
          { type: "upsellCard", attrs: { id: "stored-upsell" } },
          { type: "paragraph", content: [{ type: "text", text: "Keep me" }] },
        ],
      },
    };
    const pages = [sourcePage];

    expect(copyRichContentPages(pages, () => "new-page", "2026-07-28T01:00:00.000Z")).toEqual([
      {
        id: "new-page",
        newlyAdded: true,
        source_id: "source-page",
        title: "Source",
        updated_at: "2026-07-28T01:00:00.000Z",
        description: {
          type: "doc",
          content: [
            { type: "upsellCard", attrs: { id: null } },
            { type: "paragraph", content: [{ type: "text", text: "Keep me" }] },
          ],
        },
      },
    ]);

    const firstCopy = copyRichContentPages(pages, () => "first-copy")[0];
    if (!firstCopy) throw new Error("Expected the first copy");
    const secondCopy = copyRichContentPages([firstCopy], () => "second-copy")[0];
    if (!secondCopy) throw new Error("Expected the chained copy");
    expect(secondCopy.source_id).toBe("source-page");
    expect(secondCopy.copy_parent_id).toBe("first-copy");

    const unsavedCopy = copyRichContentPages([{ ...sourcePage, id: "unsaved", newlyAdded: true }], () => "copy");
    expect(unsavedCopy[0]?.source_id).toBeUndefined();
    expect(unsavedCopy[0]?.copy_parent_id).toBe("unsaved");
  });

  it("clears saved provenance and reconciles an in-flight copy through its source", () => {
    const savedCopy = {
      id: "sent-client-id",
      newlyAdded: true,
      source_id: "source-page",
      title: "Saved",
      updated_at: "before",
      description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: "remove" } }] },
    };
    const inFlightCopy = {
      id: "later-client-id",
      source_id: "source-page",
      title: "Not sent",
      updated_at: "before",
      description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: "remove" } }] },
    };
    const response = {
      rich_content_id_mappings: { "sent-client-id": "canonical-id" },
      rich_content_removed_file_embed_ids: { "canonical-id": ["remove"], "source-page": ["remove"] },
      rich_content_updated_at: { "canonical-id": "after" },
    };

    applyRichContentPageSaveResponse(savedCopy, response);
    applyRichContentPageSaveResponse(inFlightCopy, response);

    expect(savedCopy).toEqual({
      id: "canonical-id",
      title: "Saved",
      updated_at: "after",
      description: { type: "doc", content: [] },
    });
    expect(inFlightCopy).toEqual({
      id: "later-client-id",
      source_id: "source-page",
      title: "Not sent",
      updated_at: "before",
      description: { type: "doc", content: [] },
    });
  });

  it("rebases an in-flight chained copy to the parent row the response just created", () => {
    const sentParent = {
      id: "parent-client-id",
      newlyAdded: true,
      source_id: "original-source",
      title: "Parent copy",
      updated_at: "before",
      description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: "remove" } }] },
    };
    const descendant = copyRichContentPages([sentParent], () => "descendant-client-id")[0];
    if (!descendant) throw new Error("Expected the descendant copy");
    const response = {
      rich_content_id_mappings: { "parent-client-id": "canonical-parent" },
      rich_content_removed_file_embed_ids: { "canonical-parent": ["remove"] },
    };

    applyRichContentPageSaveResponse(sentParent, response);
    applyRichContentPageSaveResponse(descendant, response);

    expect(descendant).toMatchObject({
      id: "descendant-client-id",
      newlyAdded: true,
      source_id: "canonical-parent",
      description: { type: "doc", content: [] },
    });
    expect(descendant.copy_parent_id).toBeUndefined();
  });
});

describe("prepareRichContentPagesForMove", () => {
  const storedPage = {
    id: "stored-page",
    title: "Stored",
    updated_at: "2026-07-28T00:00:00.000Z",
    description: { type: "doc", content: [{ type: "paragraph" }] },
  };

  it("cancels a move when the page returns to its original scope before save", () => {
    const movedToVersion = prepareRichContentPagesForMove([storedPage], null, "version-1");
    expect(movedToVersion[0]).toMatchObject({
      source_id: "stored-page",
      move_source_id: "stored-page",
      move_source_scope: null,
    });
    expect(richContentMoveSourceIds({ rich_content: movedToVersion, variants: [] })).toEqual(["stored-page"]);

    const restoredToShared = prepareRichContentPagesForMove(movedToVersion, "version-1", null);
    expect(restoredToShared).toEqual([storedPage]);
    expect(richContentMoveSourceIds({ rich_content: restoredToShared, variants: [] })).toEqual([]);
  });

  it("keeps the original source when repeated toggles end in a different version", () => {
    const movedToShared = prepareRichContentPagesForMove([storedPage], "version-2", null);
    const movedToFirstVersion = prepareRichContentPagesForMove(movedToShared, null, "version-1");

    expect(movedToFirstVersion[0]).toMatchObject({
      source_id: "stored-page",
      move_source_id: "stored-page",
      move_source_scope: "version-2",
    });
  });

  it("does not delete a source row for a page that has never been saved", () => {
    const newPage = { ...storedPage, id: "client-id", newlyAdded: true };
    const moved = prepareRichContentPagesForMove([newPage], null, "version-1");

    expect(moved[0]).toMatchObject({ newlyAdded: true, move_source_scope: null });
    expect(moved[0]?.move_source_id).toBeUndefined();
    expect(richContentMoveSourceIds({ rich_content: moved, variants: [] })).toEqual([]);
  });

  it("adopts a canonical source for a move made while the page-creation save was in flight", () => {
    const sentPage = { ...storedPage, id: "client-id", newlyAdded: true };
    const currentPage = prepareRichContentPagesForMove([sentPage], null, "version-1")[0];
    if (!currentPage) throw new Error("Expected the moved page");

    applyRichContentPageSaveResponse(
      currentPage,
      { rich_content_id_mappings: { "client-id": "canonical-source" } },
      sentPage,
    );

    expect(currentPage).toMatchObject({
      id: "canonical-source",
      source_id: "canonical-source",
      move_source_id: "canonical-source",
      move_source_scope: null,
    });
    expect(currentPage.newlyAdded).toBeUndefined();
    expect(richContentMoveSourceIds({ rich_content: [currentPage], variants: [] })).toEqual(["canonical-source"]);

    const sentMove = { ...currentPage };
    applyRichContentPageSaveResponse(
      currentPage,
      { rich_content_id_mappings: { "canonical-source": "canonical-destination" } },
      sentMove,
    );
    expect(currentPage).toEqual({ ...storedPage, id: "canonical-destination" });
  });

  it("keeps a follow-up move made while the first move save was in flight", () => {
    const sentMove = prepareRichContentPagesForMove([storedPage], null, "version-1")[0];
    if (!sentMove) throw new Error("Expected the sent move");
    const currentPage = prepareRichContentPagesForMove([sentMove], "version-1", null)[0];
    if (!currentPage) throw new Error("Expected the follow-up move");

    applyRichContentPageSaveResponse(
      currentPage,
      { rich_content_id_mappings: { "stored-page": "version-row" } },
      sentMove,
      null,
      "version-1",
    );
    expect(currentPage).toMatchObject({
      id: "version-row",
      source_id: "version-row",
      move_source_id: "version-row",
      move_source_scope: "version-1",
    });

    const sentFollowUp = { ...currentPage };
    applyRichContentPageSaveResponse(
      currentPage,
      { rich_content_id_mappings: { "version-row": "shared-row" } },
      sentFollowUp,
      null,
      null,
    );
    expect(currentPage).toEqual({ ...storedPage, id: "shared-row" });
  });
});

describe("overlapping save reconciliation", () => {
  it("follows canonical ID chains after repeated saved moves", () => {
    expect(resolveServerIdMapping("first", { first: "second", second: "third" })).toBe("third");
    expect(resolveServerIdMapping("first", { first: "second", second: "first" })).toBe("first");

    const variantMappings = { "client-variant": "colliding-external-id" };
    const pageMappings = { "colliding-external-id": "moved-page-id" };
    expect(resolveServerIdMapping("client-variant", variantMappings)).toBe("colliding-external-id");
    expect(resolveServerIdMapping("colliding-external-id", pageMappings)).toBe("moved-page-id");
  });

  it("canonicalizes a sent variant scope even when the current page is shared", () => {
    expect(canonicalRichContentScope("client-variant", { "client-variant": "canonical-variant" })).toBe(
      "canonical-variant",
    );
    expect(canonicalRichContentScope(null, { "client-variant": "canonical-variant" })).toBeNull();
  });

  it("remaps a pending deletion recorded after the request began", () => {
    expect(reconcileConfirmedRemovalIds(["client-id"], new Set(), { "client-id": "canonical-id" })).toEqual([
      "canonical-id",
    ]);
    expect(reconcileConfirmedRemovalIds(["sent-id", "later-id"], new Set(["sent-id"]), undefined)).toEqual([
      "later-id",
    ]);
  });

  it("remaps and reconciles a copy whose source moved while the save was in flight", () => {
    const page = {
      id: "later-copy",
      newlyAdded: true,
      source_id: "stored-source",
      title: "Copy",
      updated_at: "before",
      description: { type: "doc", content: [{ type: "fileEmbed", attrs: { id: "dead-file" } }] },
    };

    applyRichContentPageSaveResponse(page, {
      rich_content_id_mappings: { "stored-source": "moved-source" },
      rich_content_removed_file_embed_ids: { "moved-source": ["dead-file"] },
    });
    expect(page.source_id).toBe("moved-source");
    expect(page.description).toEqual({ type: "doc", content: [] });
    expect(removedFileEmbedIdsForPage(page, { "moved-source": ["dead-file"] })).toEqual(["dead-file"]);
  });
});

describe("removeFileEmbedsFromRichContent", () => {
  it("rewrites mapped file embed ids throughout rich content", () => {
    const page = {
      id: "page",
      title: "Files",
      updated_at: "before",
      description: {
        type: "doc",
        content: [
          { type: "fileEmbed", attrs: { id: "temporary-file", uid: "file-uid" } },
          {
            type: "fileEmbedGroup",
            attrs: { uid: "group-uid" },
            content: [
              { type: "fileEmbed", attrs: { id: "temporary-file", uid: "group-file-uid" } },
              { type: "fileEmbed", attrs: { id: "keep-file", uid: "keep-uid" } },
            ],
          },
        ],
      },
    };

    applyRichContentPageSaveResponse(page, { file_id_mappings: { "temporary-file": "canonical-file" } });
    expect(page.description).toEqual({
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "canonical-file", uid: "file-uid" } },
        {
          type: "fileEmbedGroup",
          attrs: { uid: "group-uid" },
          content: [
            { type: "fileEmbed", attrs: { id: "canonical-file", uid: "group-file-uid" } },
            { type: "fileEmbed", attrs: { id: "keep-file", uid: "keep-uid" } },
          ],
        },
      ],
    });

    expect(applyFileIdMappingsToRichContent(page.description, { missing: "unused" })).toEqual(page.description);
  });

  it("removes reported embeds, prunes empty groups, and preserves other content", () => {
    const description = {
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "keep", uid: "keep-uid" } },
        {
          type: "fileEmbedGroup",
          attrs: { uid: "mixed-group" },
          content: [
            { type: "fileEmbed", attrs: { id: "remove", uid: "remove-uid" } },
            { type: "fileEmbed", attrs: { id: "keep", uid: "keep-group-uid" } },
          ],
        },
        {
          type: "fileEmbedGroup",
          attrs: { uid: "empty-group" },
          content: [{ type: "fileEmbed", attrs: { id: "remove", uid: "remove-group-uid" } }],
        },
        { type: "paragraph", content: [{ type: "text", text: "Keep this edit" }] },
      ],
    };

    expect(removeFileEmbedsFromRichContent(description, new Set(["remove"]))).toEqual({
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "keep", uid: "keep-uid" } },
        {
          type: "fileEmbedGroup",
          attrs: { uid: "mixed-group" },
          content: [{ type: "fileEmbed", attrs: { id: "keep", uid: "keep-group-uid" } }],
        },
        { type: "paragraph", content: [{ type: "text", text: "Keep this edit" }] },
      ],
    });
  });

  it("keeps the mounted-editor cleanup out of undo history", () => {
    const schema = new Schema({
      nodes: {
        doc: { content: "block+" },
        paragraph: { group: "block", content: "text*" },
        text: {},
        fileEmbedGroup: {
          group: "block",
          content: "fileEmbed+",
          attrs: { uid: {} },
        },
        fileEmbed: {
          atom: true,
          attrs: { id: { default: null }, uid: { default: null } },
        },
      },
    });
    const originalDocument = schema.nodeFromJSON({
      type: "doc",
      content: [
        {
          type: "fileEmbedGroup",
          attrs: { uid: "stale-group" },
          content: [{ type: "fileEmbed", attrs: { id: "remove", uid: "stale-uid" } }],
        },
        { type: "paragraph", content: [{ type: "text", text: "First edit" }] },
      ],
    });
    let state = EditorState.create({
      doc: originalDocument,
      plugins: [history()],
    });
    const removedGroupSize = originalDocument.child(0).nodeSize;
    const textStart = removedGroupSize + 1;
    const typedText = " pending";
    const caretBeforeCleanup = textStart + "First".length + typedText.length;
    const editTransaction = state.tr.insertText(typedText, textStart + "First".length);
    editTransaction.setSelection(TextSelection.create(editTransaction.doc, caretBeforeCleanup));
    state = state.apply(editTransaction);
    const cleanedDocument = schema.nodeFromJSON({
      type: "doc",
      content: [{ type: "paragraph", content: [{ type: "text", text: "First pending edit" }] }],
    });
    const transaction = buildRichContentReconciliationTransaction(state, new Set(["remove"]));

    expect(transaction.getMeta("addToHistory")).toBe(false);
    expect(transaction.getMeta("preventUpdate")).toBe(true);

    const reconciledState = state.apply(transaction);
    expect(reconciledState.doc.toJSON()).toEqual(cleanedDocument.toJSON());
    expect(reconciledState.selection.from).toBe(caretBeforeCleanup - removedGroupSize);

    let undoneState = reconciledState;
    expect(
      undo(reconciledState, (undoTransaction) => {
        undoneState = reconciledState.apply(undoTransaction);
      }),
    ).toBe(true);
    expect(undoneState.doc.toJSON()).toEqual({
      type: "doc",
      content: [{ type: "paragraph", content: [{ type: "text", text: "First edit" }] }],
    });
  });

  it("keeps mounted-editor file id remapping out of undo history", () => {
    const schema = new Schema({
      nodes: {
        doc: { content: "block+" },
        paragraph: { group: "block", content: "text*" },
        text: {},
        fileEmbed: {
          group: "block",
          atom: true,
          attrs: { id: { default: null }, uid: { default: null } },
        },
      },
    });
    const originalDocument = schema.nodeFromJSON({
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "temporary-file", uid: "file-uid" } },
        { type: "paragraph", content: [{ type: "text", text: "Saved text" }] },
      ],
    });
    let state = EditorState.create({
      doc: originalDocument,
      plugins: [history()],
    });
    const editTransaction = state.tr.insertText(
      " still editing",
      originalDocument.child(0).nodeSize + "Saved".length + 1,
    );
    state = state.apply(editTransaction);
    const transaction = buildRichContentFileIdMappingTransaction(state, { "temporary-file": "canonical-file" });

    expect(transaction.getMeta("addToHistory")).toBe(false);
    expect(transaction.getMeta("preventUpdate")).toBe(true);

    const reconciledState = state.apply(transaction);
    expect(reconciledState.doc.toJSON()).toEqual({
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "canonical-file", uid: "file-uid" } },
        { type: "paragraph", content: [{ type: "text", text: "Saved still editing text" }] },
      ],
    });

    let undoneState = reconciledState;
    expect(
      undo(reconciledState, (undoTransaction) => {
        undoneState = reconciledState.apply(undoTransaction);
      }),
    ).toBe(true);
    expect(undoneState.doc.toJSON()).toEqual({
      type: "doc",
      content: [
        { type: "fileEmbed", attrs: { id: "canonical-file", uid: "file-uid" } },
        { type: "paragraph", content: [{ type: "text", text: "Saved text" }] },
      ],
    });
  });
});

describe("save contract conflict responses", () => {
  // The seller-visible bug (gumroad-private#1508): the server answers a
  // stale-token deletion with 409 + error_code, but the mapping only recognised
  // the two content-conflict codes, so this one fell through to a bare
  // ResponseError and the page turned it into a generic red toast that never
  // said the deletion had not happened.
  it("maps stale_deletion_conflict to its own typed error", () => {
    const error = saveProductError({
      error_message: "This product changed since you opened it.",
      error_code: "stale_deletion_conflict",
    });

    expect(error).toBeInstanceOf(StaleDeletionConflictError);
    expect(error).not.toBeInstanceOf(StaleContentConflictError);
    expect(error.message).toBe("This product changed since you opened it.");
  });

  // A fresh token must never reach the editor: adopting it would let the
  // session's next save — still the full stale snapshot — delete AND revert
  // every field another session changed in between (gumroad-private#1532).
  // The server no longer sends one, and the payload type no longer has a field
  // to receive it, so this pins the defence in depth: even a server that
  // regressed and emitted the token could not get it onto the error.
  it("does not carry a fresh revision onto the error", () => {
    const error = saveProductError({
      error_message: "Stale.",
      error_code: "stale_deletion_conflict",
      // @ts-expect-error -- not part of SaveProductErrorPayload; a server that
      // regressed and sent it anyway must still not have it reach the editor.
      editor_revision: "revision-issued-with-the-409",
    });

    expect(error).toBeInstanceOf(StaleDeletionConflictError);
    expect(JSON.stringify({ ...error, message: error.message })).not.toContain("revision-issued-with-the-409");
  });

  // Pins the discrimination to error_code, not to HTTP status. stale-content and
  // stale-deletion are both 409 and describe different things: a write that
  // would clobber newer content vs. a deletion that did not happen.
  it("keeps the two 409 conflicts distinct", () => {
    const contentConflict = saveProductError({
      error_message: "Someone else saved.",
      error_code: "stale_content_conflict",
      stale_records: [{ type: "variant", id: "8056662", name: "ADManager-Portable" }],
    });
    expect(contentConflict).toBeInstanceOf(StaleContentConflictError);
    expect(contentConflict).not.toBeInstanceOf(StaleDeletionConflictError);

    const hiddenConflict = saveProductError({
      error_message: "Choose which content to keep.",
      error_code: "hidden_variant_content_conflict",
      hidden_variant_pages: [{ id: "p1", title: null, variant_name: null }],
    });
    expect(hiddenConflict).toBeInstanceOf(HiddenVariantContentConflictError);

    // An unrecognised code stays a plain ResponseError, so new server codes
    // degrade to the generic toast instead of being silently mis-handled.
    const unknown = saveProductError({ error_message: "Nope.", error_code: "some_future_code" });
    expect(unknown).toBeInstanceOf(ResponseError);
    expect(unknown).not.toBeInstanceOf(StaleDeletionConflictError);
  });

  it("maps unmarked_installment_plan_clear_conflict to its own typed error", () => {
    const error = saveProductError({
      error_message: "This page is out of date.",
      error_code: "unmarked_installment_plan_clear_conflict",
    });

    expect(error).toBeInstanceOf(UnmarkedInstallmentPlanClearConflictError);
    expect(error).not.toBeInstanceOf(ResponseError);
    expect(error).not.toBeInstanceOf(StaleDeletionConflictError);
    expect(error.message).toBe("This page is out of date.");
  });
});
