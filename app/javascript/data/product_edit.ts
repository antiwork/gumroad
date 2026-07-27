import { Editor, findChildren } from "@tiptap/core";
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
  // Client-generated id → canonical server id for variants/pages this save
  // created. The editor swaps its ids for these so the next save updates the
  // created records instead of re-creating them (re-creation trips the
  // server's content deletion guard and duplicates variants).
  variant_id_mappings?: Record<string, string>;
  rich_content_id_mappings?: Record<string, string>;
  // Canonical external id → fresh post-save snapshot timestamp for every
  // alive page/variant. The editor adopts these so its next save echoes the
  // timestamps this save produced — otherwise the second save of a session
  // would echo pre-save timestamps and be rejected as stale.
  rich_content_updated_at?: Record<string, string>;
  variant_updated_at?: Record<string, string>;
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

export const filesForSave = <T extends { id: string }>(
  files: T[],
  embeddedFileIds: Set<unknown>,
  keepAllFiles: boolean,
) => (keepAllFiles ? files : files.filter((file) => embeddedFileIds.has(file.id)));

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
  const { custom_html: _customHtml, ...productParams } = product;
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.link_path(permalink),
    data: {
      ...productParams,
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
      // The save contract (gumroad-private#1379). Sent on every save; the
      // server ignores both unless the :product_editor_save_contract flag is on
      // for this seller, so this is inert until the rollout enables it.
      //
      // `editor_revision` is echoed back exactly as the server issued it. It
      // gates deletions only — a save carrying no deletions is accepted from a
      // stale tab, which is why an open second tab can still fix a typo.
      editor_revision: product.editor_revision ?? null,
      deletion_operations: product.deletion_operations ?? buildDeletionOperations(product),
      availabilities: product.availabilities.map(({ newlyAdded, ...availability }) =>
        newlyAdded ? { ...availability, id: null } : availability,
      ),
      installment_plan: product.allow_installment_plan ? product.installment_plan : null,
    },
  });
  if (!response.ok) {
    const error = typia.assert<{
      error_message: string;
      error_code?: string;
      hidden_variant_pages?: { id: string; title: string | null; variant_name: string | null }[];
      stale_records?: { type: "page" | "variant"; id: string; name: string | null }[];
    }>(await response.json());
    if (error.error_code === "hidden_variant_content_conflict")
      throw new HiddenVariantContentConflictError(error.error_message, error.hidden_variant_pages ?? []);
    if (error.error_code === "stale_content_conflict")
      throw new StaleContentConflictError(error.error_message, error.stale_records ?? []);
    throw new ResponseError(error.error_message);
  }
  if (response.status === 204) return {};
  return typia.assert<SaveProductResponse>(await response.json());
};
