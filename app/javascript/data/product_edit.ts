import { Editor, findChildren, Node as TiptapNode } from "@tiptap/core";
import { cast } from "ts-safe-cast";

import { CurrencyCode } from "$app/utils/currency";
import { ResponseError, request } from "$app/utils/request";

import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { FileEmbedGroup } from "$app/components/ProductEdit/ContentTab/FileEmbedGroup";
import { Product } from "$app/components/ProductEdit/state";
import { baseEditorOptions } from "$app/components/RichTextEditor";
import { FileUpload } from "$app/components/TiptapExtensions/FileUpload";
import { LicenseKey } from "$app/components/TiptapExtensions/LicenseKey";
import { LongAnswer } from "$app/components/TiptapExtensions/LongAnswer";
import { ExternalMediaFileEmbed } from "$app/components/TiptapExtensions/MediaEmbed";
import { MoreLikeThis } from "$app/components/TiptapExtensions/MoreLikeThis";
import { MoveNode } from "$app/components/TiptapExtensions/MoveNode";
import { Posts } from "$app/components/TiptapExtensions/Posts";
import { ShortAnswer } from "$app/components/TiptapExtensions/ShortAnswer";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";

export const extensions = (productId: string, extraExtensions: TiptapNode[] = []) => [
  ...extraExtensions,
  ...[
    FileEmbed,
    FileEmbedGroup,
    ExternalMediaFileEmbed,
    Posts,
    LicenseKey,
    ShortAnswer,
    LongAnswer,
    FileUpload,
    MoveNode,
    UpsellCard,
    MoreLikeThis.configure({ productId }),
  ].filter((ext) => !extraExtensions.some((existing) => existing.name === ext.name)),
];

export const saveProduct = async (permalink: string, id: string, product: Product, currencyType: CurrencyCode) => {
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
  product.files = product.files.filter((file) => fileIds.has(file.id));

  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.link_path(permalink),
    data: {
      ...product,
      price_currency_type: currencyType,
      covers: product.covers.map(({ id }) => id),
      variants: product.variants.map(({ newlyAdded, ...variant }) => (newlyAdded ? { ...variant, id: null } : variant)),
      availabilities: product.availabilities.map(({ newlyAdded, ...availability }) =>
        newlyAdded ? { ...availability, id: null } : availability,
      ),
      installment_plan: product.allow_installment_plan ? product.installment_plan : null,
    },
  });
  if (!response.ok) throw new ResponseError(cast<{ error_message: string }>(await response.json()).error_message);
  if (response.status === 204) return {};
  return cast<{ warning_message?: string }>(await response.json());
};
