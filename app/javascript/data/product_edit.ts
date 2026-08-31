import { Editor, findChildren } from "@tiptap/core";
import { type Mark } from "@tiptap/pm/model";
import { EditorState, Transaction } from "@tiptap/pm/state";
import typia from "typia";

import { buildDeletionOperations } from "$app/data/product_save_contract";
import { CurrencyCode } from "$app/utils/currency";
import { ResponseError, request } from "$app/utils/request";

import { extensions } from "$app/components/ProductEdit/ContentTab";
import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { Product } from "$app/components/ProductEdit/state";
import { baseEditorOptions } from "$app/components/RichTextEditor";

export type SaveProductResponse = {
  warning_message?: string;
  // Client-generated id → canonical server id for variants/pages/files this save
  // created. The editor swaps its ids for these so the next save updates the
  // created records instead of re-creating them (re-creation trips the
  // server's content deletion guard, duplicates variants, or re-attaches files).
  variant_id_mappings?: Record<string, string>;
  rich_content_id_mappings?: Record<string, string>;
  rich_content_id_mappings_by_scope?: Record<string, Record<string, string>>;
  file_id_mappings?: Record<string, string>;
  // Canonical page id → file external ids removed while repairing legacy
  // content. The editor removes the same invisible nodes from its live state,
  // otherwise its next save would resubmit them as newly introduced embeds.
  rich_content_removed_file_embed_ids?: Record<string, string[]>;
  // Canonical external id → fresh post-save snapshot timestamp for every
  // alive page/variant. The editor adopts these so its next save echoes the
  // timestamps this save produced — otherwise the second save of a session
  // would echo pre-save timestamps and be rejected as stale.
  rich_content_updated_at?: Record<string, string>;
  variant_updated_at?: Record<string, string>;
  // The revision token for the state this save committed. Every successful
  // save moves the product's fingerprint, so the token the editor loaded with
  // is stale as soon as the first save returns; the editor adopts this one so a
  // deletion later in the same session isn't refused as stale.
  editor_revision?: string | null;
  // Which integrations are connected as of the state this save committed. The
  // editor adopts this as its new baseline so a disconnect later in the same
  // session is recognised as a removal — see applyCanonicalIds.
  loaded_integrations?: Record<string, boolean>;
  // The same baseline, per version, keyed by variant external id.
  variant_loaded_integrations?: Record<string, Record<string, boolean>>;
};

// The server's fail-closed answer when a save would delete version-level pages
// that are hidden by the "use the same content for all versions" flag while
// real product-level content also exists: neither side can be picked
// automatically, so the seller must make an explicit choice. Carries the
// hidden pages so the editor can present that choice.
export class HiddenVariantContentConflictError extends Error {
  constructor(
    message: string,
    public hiddenPages: { id: string; title: string | null; variant_name: string | null }[],
  ) {
    super(message);
  }
}

// The server's rejection of a save built from a stale snapshot: pages or
// variants in the payload echoed snapshot timestamps older than the stored
// rows, meaning another session saved after this session loaded. Saving would
// silently overwrite that newer content, so the server refuses before any
// mutation (see the server's Product::StaleContentWriteGuard). Carries the
// conflicting records so the editor can show the seller what changed and
// offer a reload.
export class StaleContentConflictError extends Error {
  constructor(
    message: string,
    public staleRecords: { type: "page" | "variant"; id: string; name: string | null }[],
  ) {
    super(message);
  }
}

// The save contract's refusal of a deletion authorised by a token that no
// longer describes the stored state (see Product::SaveContract). Raised before
// any mutation, so nothing was written and the removals are still pending in
// this editor session.
//
// The 409 carries NO fresh `editor_revision`, and must not: adopting one would
// authorise the session's next save — still the full stale snapshot — to delete,
// so the deletion would go through while every field another session changed in
// the meantime got reverted to this session's values. The seller confirmed a
// deletion, not an overwrite. Retrying safely means reconciling against current
// stored state, or a payload that can only delete; neither exists yet
// (gumroad-private#1532), so the recovery here is a reload — which issues a
// current token of its own.
export class StaleDeletionConflictError extends Error {}

// The server's error payload for a rejected save. Every conflict the editor can
// act on is discriminated by `error_code`, never by HTTP status: stale-content
// and stale-deletion both answer 409 but demand opposite handling (reload vs.
// retry), so status alone cannot tell them apart.
export type SaveProductErrorPayload = {
  error_message: string;
  error_code?: string;
  hidden_variant_pages?: { id: string; title: string | null; variant_name: string | null }[];
  stale_records?: { type: "page" | "variant"; id: string; name: string | null }[];
};

export const saveProductError = (error: SaveProductErrorPayload): Error => {
  switch (error.error_code) {
    case "hidden_variant_content_conflict":
      return new HiddenVariantContentConflictError(error.error_message, error.hidden_variant_pages ?? []);
    case "stale_content_conflict":
      return new StaleContentConflictError(error.error_message, error.stale_records ?? []);
    case "stale_deletion_conflict":
      return new StaleDeletionConflictError(error.error_message);
    default:
      return new ResponseError(error.error_message);
  }
};

export const filesForSave = <T extends { id: string }>(
  files: T[],
  embeddedFileIds: Set<unknown>,
  keepAllFiles: boolean,
) => (keepAllFiles ? files : files.filter((file) => embeddedFileIds.has(file.id)));

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null;

const stripUpsellIds = (value: unknown): unknown => {
  if (Array.isArray(value)) return value.map(stripUpsellIds);
  if (!isRecord(value)) return value;

  const cloned = { ...value };
  if (cloned.type === "upsellCard" && isRecord(cloned.attrs)) {
    cloned.attrs = { ...cloned.attrs, id: null };
  }
  if ("content" in cloned) cloned.content = stripUpsellIds(cloned.content);
  return cloned;
};

export const copyRichContentPages = (
  pages: Product["rich_content"],
  generateId: () => string,
  updatedAt = new Date().toISOString(),
): Product["rich_content"] =>
  pages.map((page) => {
    const stripped = stripUpsellIds(page.description);
    const sourceId = page.source_id ?? (page.newlyAdded ? undefined : page.id);
    return {
      id: generateId(),
      newlyAdded: true,
      ...(sourceId ? { source_id: sourceId } : {}),
      ...(page.newlyAdded ? { copy_parent_id: page.id } : {}),
      title: page.title,
      description: stripped !== null && typeof stripped === "object" ? stripped : page.description,
      updated_at: updatedAt,
    };
  });

export const hasMoveSourceScope = (page: Product["rich_content"][number]) =>
  Object.prototype.hasOwnProperty.call(page, "move_source_scope");

// Moves pages between the shared scope (null) and a version scope (its id).
// The marker records explicit user intent without authorising a deletion yet:
// reversing the toggle cancels it, while a save turns move_source_id into the
// exact source-row deletion. A page that has never been saved has no source
// row, so it records the scope transition but not a deletion id.
export const prepareRichContentPagesForMove = (
  pages: Product["rich_content"],
  sourceScope: string | null,
  destinationScope: string | null,
): Product["rich_content"] =>
  pages.map((page) => {
    const moved = { ...page };
    if (hasMoveSourceScope(page) && page.move_source_scope === destinationScope) {
      const moveSourceId = moved.move_source_id;
      delete moved.move_source_scope;
      delete moved.move_source_id;
      if (moveSourceId && moved.source_id === moveSourceId) delete moved.source_id;
      return moved;
    }

    if (!hasMoveSourceScope(page)) {
      moved.move_source_scope = sourceScope;
      if (!moved.newlyAdded) {
        moved.move_source_id = moved.id;
        moved.source_id = moved.id;
      }
    }
    return moved;
  });

export const richContentMoveSourceIds = (product: Pick<Product, "rich_content" | "variants">): string[] => [
  ...new Set(
    [...product.rich_content, ...product.variants.flatMap((variant) => variant.rich_content)].flatMap((page) =>
      page.move_source_id ? [page.move_source_id] : [],
    ),
  ),
];

export const removedFileEmbedIdsForPage = (
  page: Product["rich_content"][number] | undefined,
  removedIdsByPage: Record<string, string[]>,
): string[] | undefined =>
  page ? (removedIdsByPage[page.id] ?? (page.source_id ? removedIdsByPage[page.source_id] : undefined)) : undefined;

export const reconcileConfirmedRemovalIds = (
  currentIds: string[],
  sentIds: ReadonlySet<string>,
  idMappings: Record<string, string> | undefined,
): string[] => [...new Set(currentIds.filter((id) => !sentIds.has(id)).map((id) => idMappings?.[id] ?? id))];

export const resolveServerIdMapping = (id: string, idMappings: Record<string, string>): string => {
  let resolved = id;
  const seen = new Set<string>();
  while (!seen.has(resolved)) {
    const next = idMappings[resolved];
    if (!next) break;
    seen.add(resolved);
    resolved = next;
  }
  return resolved;
};

export const canonicalRichContentScope = (
  scope: string | null | undefined,
  variantIdMappings: Record<string, string>,
): string | null | undefined => (typeof scope === "string" ? (variantIdMappings[scope] ?? scope) : scope);

export const scopedRichContentPageKey = (scope: string | null, id: string) => `${scope ?? ""}\u0000${id}`;

export const applyRichContentPageSaveResponse = (
  page: Product["rich_content"][number],
  response: SaveProductResponse,
  sentPage: Product["rich_content"][number] = page,
  currentScope?: string | null,
  sentScope?: string | null,
  mappingScope: string | null | undefined = sentScope,
): void => {
  const originalId = page.id;
  const wasNewlyAdded = page.newlyAdded;
  const currentMoveWasSent =
    hasMoveSourceScope(page) &&
    hasMoveSourceScope(sentPage) &&
    page.move_source_scope === sentPage.move_source_scope &&
    page.move_source_id === sentPage.move_source_id;
  const hasScopeContext = currentScope !== undefined && sentScope !== undefined;
  const movedAfterRequest = hasScopeContext && currentScope !== sentScope;
  const mappedSourceId = page.source_id ? response.rich_content_id_mappings?.[page.source_id] : undefined;
  if (mappedSourceId) page.source_id = mappedSourceId;
  const mappedCopyParentId = page.copy_parent_id ? response.rich_content_id_mappings?.[page.copy_parent_id] : undefined;
  if (mappedCopyParentId) {
    page.source_id = mappedCopyParentId;
    delete page.copy_parent_id;
  }
  const mappedMoveSourceId = page.move_source_id ? response.rich_content_id_mappings?.[page.move_source_id] : undefined;
  if (mappedMoveSourceId) page.move_source_id = mappedMoveSourceId;
  const mappedMoveSourceScope =
    typeof page.move_source_scope === "string" ? response.variant_id_mappings?.[page.move_source_scope] : undefined;
  if (mappedMoveSourceScope) page.move_source_scope = mappedMoveSourceScope;
  const canonicalId =
    (mappingScope !== undefined
      ? response.rich_content_id_mappings_by_scope?.[mappingScope ?? ""]?.[originalId]
      : undefined) ?? response.rich_content_id_mappings?.[originalId];
  if (canonicalId) {
    page.id = canonicalId;
    delete page.newlyAdded;
    if (movedAfterRequest) {
      // This response committed the page in sentScope, but the seller moved it
      // again while the request was running. The row just created is now the
      // exact source the next save must remove.
      page.move_source_scope = sentScope;
      page.move_source_id = canonicalId;
      page.source_id = canonicalId;
      delete page.copy_parent_id;
    } else if (hasScopeContext || currentMoveWasSent) {
      // This response committed the destination and deleted its source.
      // Matching owner scopes also cover a toggle away and back while the save
      // ran: the canonical row already exists in the final scope, so no
      // follow-up move remains.
      delete page.move_source_scope;
      delete page.move_source_id;
      delete page.source_id;
      delete page.copy_parent_id;
    } else if (hasMoveSourceScope(page) && wasNewlyAdded) {
      // The page was created in its original scope by this request, then moved
      // while the request was in flight. Its canonical id is now the source
      // the next save must delete.
      page.move_source_id = canonicalId;
      page.source_id = canonicalId;
      delete page.copy_parent_id;
    } else if (page.source_id === sentPage.source_id) {
      // A copied page's source id is temporary proof for this creation. Clear
      // it only when the completed request carried the same proof; an in-flight
      // copy or move must keep its own provenance for the next save.
      delete page.source_id;
      delete page.copy_parent_id;
    }
  }

  if (response.file_id_mappings && Object.keys(response.file_id_mappings).length > 0) {
    page.description = applyFileIdMappingsToRichContent(page.description, response.file_id_mappings);
  }
  const removedIds = removedFileEmbedIdsForPage(page, response.rich_content_removed_file_embed_ids ?? {});
  if (removedIds?.length) {
    page.description = removeFileEmbedsFromRichContent(page.description, new Set(removedIds));
  }
  const timestamp = response.rich_content_updated_at?.[page.id];
  if (timestamp) page.updated_at = timestamp;
};

const applyFileIdMappings = (value: unknown, fileIdMappings: Record<string, string>): unknown => {
  if (Array.isArray(value)) return value.map((child) => applyFileIdMappings(child, fileIdMappings));
  if (!isRecord(value)) return value;

  const mapped = { ...value };
  if (
    mapped.type === "fileEmbed" &&
    isRecord(mapped.attrs) &&
    typeof mapped.attrs.id === "string" &&
    fileIdMappings[mapped.attrs.id]
  ) {
    mapped.attrs = { ...mapped.attrs, id: fileIdMappings[mapped.attrs.id] };
  }
  if ("content" in mapped) mapped.content = applyFileIdMappings(mapped.content, fileIdMappings);
  return mapped;
};

export const applyFileIdMappingsToRichContent = (
  description: object,
  fileIdMappings: Record<string, string>,
): object => {
  const mapped = applyFileIdMappings(description, fileIdMappings);
  return isRecord(mapped) ? mapped : description;
};

const removeFileEmbeds = (value: unknown, fileIds: Set<string>): unknown => {
  if (Array.isArray(value)) {
    return value.map((child) => removeFileEmbeds(child, fileIds)).filter((child) => child !== null);
  }
  if (!isRecord(value)) return value;

  if (
    value.type === "fileEmbed" &&
    isRecord(value.attrs) &&
    typeof value.attrs.id === "string" &&
    fileIds.has(value.attrs.id)
  ) {
    return null;
  }

  if (!Array.isArray(value.content)) return value;

  const content = value.content.map((child) => removeFileEmbeds(child, fileIds)).filter((child) => child !== null);
  if (value.type === "fileEmbedGroup" && content.length === 0) return null;

  return { ...value, content };
};

export const removeFileEmbedsFromRichContent = (description: object, fileIds: Set<string>): object => {
  const cleaned = removeFileEmbeds(description, fileIds);
  return isRecord(cleaned) ? cleaned : description;
};

export const buildRichContentReconciliationTransaction = (
  state: EditorState,
  removedFileIds: Set<string>,
): Transaction => {
  const deletions: { from: number; to: number }[] = [];
  state.doc.descendants((node, pos) => {
    if (node.type.name === "fileEmbedGroup") {
      const removeWholeGroup =
        node.childCount > 0 &&
        Array.from({ length: node.childCount }, (_, index) => node.child(index)).every(
          (child) => child.type.name === FileEmbed.name && removedFileIds.has(String(child.attrs.id)),
        );
      if (removeWholeGroup) {
        deletions.push({ from: pos, to: pos + node.nodeSize });
        return false;
      }
    }

    if (node.type.name === FileEmbed.name && removedFileIds.has(String(node.attrs.id))) {
      deletions.push({ from: pos, to: pos + node.nodeSize });
      return false;
    }

    return true;
  });

  const transaction = state.tr;
  for (const deletion of deletions.sort((left, right) => right.from - left.from)) {
    transaction.delete(deletion.from, deletion.to);
  }
  transaction.setMeta("addToHistory", false);
  transaction.setMeta("preventUpdate", true);
  return transaction;
};

export const buildRichContentFileIdMappingTransaction = (
  state: EditorState,
  fileIdMappings: Record<string, string>,
): Transaction => {
  const updates: { pos: number; attrs: Record<string, unknown>; marks: readonly Mark[] }[] = [];
  state.doc.descendants((node, pos) => {
    if (node.type.name === FileEmbed.name && typeof node.attrs.id === "string") {
      const canonicalId = fileIdMappings[node.attrs.id];
      if (canonicalId) updates.push({ pos, attrs: { ...node.attrs, id: canonicalId }, marks: node.marks });
    }
    return true;
  });

  const transaction = state.tr;
  for (const update of updates) {
    transaction.setNodeMarkup(update.pos, undefined, update.attrs, update.marks);
  }
  transaction.setMeta("addToHistory", false);
  transaction.setMeta("preventUpdate", true);
  return transaction;
};

export const reconcileMountedEditorFileEmbeds = (editor: Editor, removedFileIds: string[]): void => {
  const transaction = buildRichContentReconciliationTransaction(editor.state, new Set(removedFileIds));
  if (transaction.docChanged) editor.view.dispatch(transaction);
};

export const reconcileMountedEditorFileEmbedIds = (editor: Editor, fileIdMappings: Record<string, string>): void => {
  const transaction = buildRichContentFileIdMappingTransaction(editor.state, fileIdMappings);
  if (transaction.docChanged) editor.view.dispatch(transaction);
};

// Omit a null/empty custom URL so a content-tab snapshot cannot clear a slug
// the seller set on a previous save. A non-empty slug is still sent.
export const scalarSettingsForSave = (product: { custom_permalink: string | null }) =>
  product.custom_permalink ? { custom_permalink: product.custom_permalink } : {};

export const saveProduct = async (
  permalink: string,
  id: string,
  product: Product,
  currencyType: CurrencyCode,
  // The "keep version content" conflict resolution submits NO rich content
  // (the kept pages were never loaded into this session), so filtering files
  // by the file-embeds found in the submitted content would wrongly delete
  // every file — including the ones the kept pages embed. Skip the filter.
  options: { keepAllFiles?: boolean } = {},
): Promise<SaveProductResponse> => {
  // TODO remove this once we have a better content uploader
  const editor = new Editor(baseEditorOptions(extensions(id)));
  const richContents =
    product.has_same_rich_content_for_all_variants || !product.variants.length
      ? product.rich_content
      : product.variants.flatMap((variant) => variant.rich_content);
  const fileIds = new Set(
    richContents.flatMap((content) =>
      findChildren(
        editor.schema.nodeFromJSON(content.description),
        (node) => node.type.name === FileEmbed.name,
      ).map<unknown>((child) => child.node.attrs.id),
    ),
  );
  editor.destroy();
  // Do not mutate the editor state here. If this request returns a hidden
  // content conflict, the seller's choice retries the save with the same
  // in-memory product. Removing files from it on the failed first attempt
  // would make "Keep version content" delete files embedded in the hidden
  // pages even though that retry asks us to preserve every file.
  const files = filesForSave(product.files, fileIds, options.keepAllFiles ?? false);
  const { custom_html: _customHtml, custom_permalink, ...productParams } = product;
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.link_path(permalink),
    data: {
      ...productParams,
      ...scalarSettingsForSave({ custom_permalink }),
      files,
      price_currency_type: currencyType,
      covers: product.covers.map(({ id }) => id),
      // Variants created in this session are sent with id: null (the server
      // assigns the canonical id) plus the client's own id as client_id so
      // the response can map one to the other.
      variants: product.variants.map(({ newlyAdded, ...variant }) =>
        newlyAdded ? { ...variant, id: null, client_id: variant.id } : variant,
      ),
      confirmed_removed_variant_ids: product.confirmed_removed_variant_ids ?? [],
      confirmed_removed_rich_content_ids: product.confirmed_removed_rich_content_ids ?? [],
      preserved_rich_content_ids: product.preserved_rich_content_ids ?? [],
      // Lets the server distinguish this provenance-aware payload from a save
      // sent by an editor tab that was already open when provenance shipped.
      // The compatibility path for those older tabs can then stay narrow and
      // disappear once no such sessions remain.
      rich_content_provenance_version: 2,
      // The save contract (gumroad-private#1379). Sent on every save; the
      // server ignores both unless the :product_editor_save_contract flag is on
      // for this seller, so this is inert until the rollout enables it.
      //
      // `editor_revision` is echoed back exactly as the server issued it. It
      // gates deletions only — a save carrying no deletions is accepted from a
      // stale tab, which is why an open second tab can still fix a typo.
      editor_revision: product.editor_revision ?? null,
      // Always derived, never taken from product state. The seller's confirmed
      // removals are the single source of truth; an override here would let a
      // stale or partially-built operations block outrank them and produce a
      // save that reports success and deletes nothing (gumroad-private#1508).
      deletion_operations: buildDeletionOperations(product),
      availabilities: product.availabilities.map(({ newlyAdded, ...availability }) =>
        newlyAdded ? { ...availability, id: null } : availability,
      ),
      installment_plan: product.allow_installment_plan ? product.installment_plan : null,
    },
  });
  if (!response.ok) throw saveProductError(typia.assert<SaveProductErrorPayload>(await response.json()));
  if (response.status === 204) return {};
  return typia.assert<SaveProductResponse>(await response.json());
};
