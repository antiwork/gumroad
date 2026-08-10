// @vitest-environment happy-dom
import { cleanup, render, act } from "@testing-library/react";
import type { Editor } from "@tiptap/core";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { ContentTabContent } from "$app/components/ProductEdit/ContentTab";
import { Product } from "$app/components/ProductEdit/state";

// Capture the real mounted TipTap editor so the test can fire an update inside
// the deferred page-switch window that editorContentPageIdRef guards (gp#1943).
let mountedEditor: Editor | null = null;

// vite.config.ts replaces the bare `SSR` identifier at build time.
Object.assign(globalThis, { SSR: false });

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
    useRichTextEditor: (options: Parameters<typeof mod.useRichTextEditor>[0]) => {
      const editor = mod.useRichTextEditor(options);
      mountedEditor = editor;
      return editor;
    },
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
  cleanup();
  mountedEditor = null;
});

const getMountedEditor = () => {
  if (!mountedEditor) throw new Error("Editor did not mount");
  return mountedEditor;
};

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

it("rejects a stale variant write, resets the real editor, and persists the next edit", async () => {
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

  const { rerender } = render(<ContentTabContent selectedVariantId="variant-paid" />);
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("PAID PAGE");

  // The real hook still holds the paid doc until its reset microtask runs.
  rerender(<ContentTabContent selectedVariantId="variant-free" />);
  expect(getMountedEditor().getText()).toBe("PAID PAGE");
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  getMountedEditor().emit("update", { editor: getMountedEditor(), transaction: null } as never);
  expect(freeVariant.rich_content[0]?.description).toEqual(freePage.description);

  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("FREE PAGE");

  act(() => {
    getMountedEditor().chain().focus("end").insertContent(" EDITED").run();
  });
  expect(getMountedEditor().getText()).toBe("FREE PAGE EDITED");
  expect(freeVariant.rich_content[0]?.description).toEqual(getMountedEditor().getJSON());
  expect(paidVariant.rich_content[0]?.description).toEqual(paidPage.description);
});
