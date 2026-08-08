// @vitest-environment happy-dom
import { cleanup, render, act } from "@testing-library/react";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { ContentTabContent } from "$app/components/ProductEdit/ContentTab";
import { Product } from "$app/components/ProductEdit/state";

// The mounted TipTap editor is provided by the mocked hook so this test can fire an
// update/blur handler synchronously, inside the deferred page-switch window that
// editorContentPageIdRef guards (gumroad-private#1943).
let mountedEditor: Editor | null = null;

const context = vi.hoisted(() => ({
  id: "product-id",
  product: {},
  updateProduct: (_update: unknown) => {},
  save: () => Promise.resolve(true),
  existingFiles: [],
  setExistingFiles: () => {},
  uniquePermalink: "permalink",
  filesById: new Map(),
  richContentIdMappings: {},
  fileIdMappings: {},
  richContentRemovedFileEmbedIds: {},
}));

vi.mock("$app/components/ProductEdit/state", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/ProductEdit/state")>();
  return {
    ...mod,
    useProductEditContext: () => context,
  };
});

vi.mock("$app/components/RichTextEditor", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/RichTextEditor")>();
  return {
    ...mod,
    useRichTextEditor: () => mountedEditor,
    RichTextEditorToolbar: () => null,
    useImageUploadSettings: () => ({ isUploading: false, onUpload: () => {}, allowedExtensions: [] }),
  };
});

vi.mock("$app/components/ProductEdit/Layout", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/ProductEdit/Layout")>();
  return { ...mod, useProductUrl: () => "#" };
});
vi.mock("$app/components/EvaporateUploader", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/EvaporateUploader")>();
  return {
    ...mod,
    useEvaporateUploader: () => ({ scheduleUpload: () => 0, cancelUpload: () => {} }),
  };
});
vi.mock("$app/components/S3UploadConfig", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/S3UploadConfig")>();
  return {
    ...mod,
    useS3UploadConfig: () => ({ generateS3KeyForUpload: () => ({ s3key: "key", fileUrl: "url" }) }),
  };
});
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));
vi.mock("$app/components/ReviewForm", () => ({ ReviewForm: () => null }));
vi.mock("$app/components/UpsellSelectModal", () => ({ UpsellSelectModal: () => null }));
vi.mock("$app/components/TestimonialSelectModal", () => ({ TestimonialSelectModal: () => null }));
vi.mock("$app/components/ProductEdit/ContentTab/EpubNudge", () => ({ EpubNudge: () => null }));
vi.mock("react-sortablejs", () => ({
  default: ({ children }: { children: React.ReactNode }) => children,
  ReactSortable: ({ children }: { children: React.ReactNode }) => children,
}));

afterEach(() => {
  mountedEditor?.destroy();
  mountedEditor = null;
  cleanup();
});

const makePage = (id: string, text: string) => ({
  id,
  title: null,
  description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text }] }] } as const,
  updated_at: "2026-01-01T00:00:00.000Z",
});

type VariantFixture = {
  id: string;
  name: string;
  rich_content: ReturnType<typeof makePage>[];
};

const buildProduct = (variants: VariantFixture[]): Product =>
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- fixture only needs the fields ContentTabContent reads
  ({
    id: "product-id",
    name: "Product",
    native_type: "digital",
    variants,
    rich_content: [],
    files: [],
  }) as unknown as Product;

it("does not write the previous variant's mounted doc into the newly selected variant during the page-switch window", async () => {
  const paidPage = makePage("page-paid-1", "PAID PAGE");
  const freePage = makePage("page-free-1", "FREE PAGE");
  const paidVariant: VariantFixture = { id: "variant-paid", name: "Paid", rich_content: [paidPage] };
  const freeVariant: VariantFixture = { id: "variant-free", name: "Free", rich_content: [freePage] };
  const product = buildProduct([paidVariant, freeVariant]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  mountedEditor = new Editor({
    extensions: [StarterKit],
    content: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text", text: "PAID PAGE" }] }] },
  });

  const { rerender } = render(<ContentTabContent selectedVariantId="variant-paid" />);
  await act(async () => {});

  // Switch to the free variant; the mounted ProseMirror doc is only swapped in a
  // deferred microtask. An update/blur firing synchronously here must not be
  // serialized into the free variant's page.
  rerender(<ContentTabContent selectedVariantId="variant-free" />);
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  mountedEditor.emit("update", { editor: mountedEditor, transaction: null } as never);

  await act(async () => {});
  expect(freeVariant.rich_content[0]?.description).toEqual(freePage.description);
});
