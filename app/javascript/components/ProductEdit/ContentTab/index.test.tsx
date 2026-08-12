// @vitest-environment happy-dom
import { cleanup, render, act } from "@testing-library/react";
import type { Editor } from "@tiptap/core";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { ContentTabContent, rawDocContainsNode } from "$app/components/ProductEdit/ContentTab";
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
const alerts = vi.hoisted((): { message: string; level: string }[] => []);
vi.mock("$app/components/server-components/Alert", () => ({
  showAlert: (message: string, level: string) => alerts.push({ message, level }),
}));

afterEach(() => {
  cleanup();
  mountedEditor = null;
  alerts.length = 0;
});

const getMountedEditor = () => {
  if (!mountedEditor) throw new Error("Editor did not mount");
  return mountedEditor;
};

const makePage = (id: string, text: string, title: string | null = null) => ({
  id,
  title,
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

// A failed reset leaves the previous doc mounted; writes must stay blocked
// and the seller alerted (gumroad-private#2023).
it("blocks writes and alerts when the newly selected page's doc cannot be parsed", async () => {
  const paidPage = makePage("page-paid-1", "PAID PAGE");
  // A known node type with an invalid shape: dropUnknownNodes keeps it, and
  // ProseMirror's nodeFromJSON throws on a text node without text.
  const poisonPage = {
    id: "page-free-1",
    title: null,
    description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text" }] }] },
    updated_at: "2026-01-01T00:00:00.000Z",
  };
  const paidVariant: VariantFixture = { id: "variant-paid", name: "Paid", rich_content: [paidPage] };
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the poison doc is deliberately malformed
  const freeVariant = { id: "variant-free", name: "Free", rich_content: [poisonPage] } as unknown as VariantFixture;
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

  rerender(<ContentTabContent selectedVariantId="variant-free" />);
  await act(async () => {});
  // The poison doc failed to mount; writes must not land under the free page.
  expect(getMountedEditor().getText()).toBe("PAID PAGE");
  expect(alerts).toContainEqual({
    message: "This page's content could not be displayed. Reload the page before editing it.",
    level: "error",
  });
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  getMountedEditor().emit("update", { editor: getMountedEditor(), transaction: null } as never);
  expect(freeVariant.rich_content[0]?.description).toEqual(poisonPage.description);

  // Switching back to a parseable page recovers, and edits land on it.
  rerender(<ContentTabContent selectedVariantId="variant-paid" />);
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("PAID PAGE");
  act(() => {
    getMountedEditor().chain().focus("end").insertContent(" EDITED").run();
  });
  expect(paidVariant.rich_content[0]?.description).toEqual(getMountedEditor().getJSON());
});

// useEditor mounts an EMPTY doc for a malformed first page; writes must stay
// blocked from the start or a blur overwrites the stored content.
it("blocks writes and alerts when the initially selected page's doc cannot be parsed", async () => {
  const poisonPage = {
    id: "page-free-1",
    title: null,
    description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text" }] }] },
    updated_at: "2026-01-01T00:00:00.000Z",
  };
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the poison doc is deliberately malformed
  const freeVariant = { id: "variant-free", name: "Free", rich_content: [poisonPage] } as unknown as VariantFixture;
  const product = buildProduct([freeVariant]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  render(<ContentTabContent selectedVariantId="variant-free" />);
  await act(async () => {});

  expect(alerts).toContainEqual({
    message: "This page's content could not be displayed. Reload the page before editing it.",
    level: "error",
  });
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  getMountedEditor().emit("update", { editor: getMountedEditor(), transaction: null } as never);
  expect(freeVariant.rich_content[0]?.description).toEqual(poisonPage.description);
});

// The fallback for unparseable docs must stay fail-closed for single-instance
// node checks (license key): a malformed doc can still carry the node.
it("finds a node in a raw doc that also contains invalid nodes", () => {
  const doc = {
    type: "doc",
    content: [
      { type: "paragraph", content: [{ type: "text" }] },
      { type: "licenseKey", attrs: {} },
    ],
  };
  expect(rawDocContainsNode(doc, "licenseKey")).toBe(true);
  expect(rawDocContainsNode(doc, "posts")).toBe(false);
  expect(rawDocContainsNode(null, "licenseKey")).toBe(false);
  expect(
    rawDocContainsNode(
      { type: "doc", content: [{ type: "blockquote", content: [{ type: "licenseKey" }] }] },
      "licenseKey",
    ),
  ).toBe(true);
});

// Two variants' pages can share a raw id before save reconciliation, so the
// reset and the write guard must key on scope + id.
it("re-mounts the doc and scopes writes when two variants' pages share a raw id", async () => {
  const tierAPage = makePage("shared-id", "TIER A DOC");
  const tierBPage = makePage("shared-id", "TIER B DOC");
  const tierA: VariantFixture = { id: "variant-a", name: "A", rich_content: [tierAPage] };
  const tierB: VariantFixture = { id: "variant-b", name: "B", rich_content: [tierBPage] };
  const product = buildProduct([tierA, tierB]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  const { rerender } = render(<ContentTabContent selectedVariantId="variant-a" />);
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("TIER A DOC");

  rerender(<ContentTabContent selectedVariantId="variant-b" />);
  // Switch window: a write must not land under tier B's same-id page.
  expect(getMountedEditor().getText()).toBe("TIER A DOC");
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  getMountedEditor().emit("update", { editor: getMountedEditor(), transaction: null } as never);
  expect(tierB.rich_content[0]?.description).toEqual(tierBPage.description);

  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("TIER B DOC");
  act(() => {
    getMountedEditor().chain().focus("end").insertContent(" EDITED").run();
  });
  expect(tierB.rich_content[0]?.description).toEqual(getMountedEditor().getJSON());
  expect(tierA.rich_content[0]?.description).toEqual(tierAPage.description);
});

it("blocks writes and alerts when a same-id page in another variant cannot be parsed", async () => {
  const tierAPage = makePage("shared-id", "TIER A DOC");
  const poisonPage = {
    id: "shared-id",
    title: null,
    description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text" }] }] },
    updated_at: "2026-01-01T00:00:00.000Z",
  };
  const tierA: VariantFixture = { id: "variant-a", name: "A", rich_content: [tierAPage] };
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the poison doc is deliberately malformed
  const tierB = { id: "variant-b", name: "B", rich_content: [poisonPage] } as unknown as VariantFixture;
  const product = buildProduct([tierA, tierB]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  const { rerender } = render(<ContentTabContent selectedVariantId="variant-a" />);
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("TIER A DOC");

  rerender(<ContentTabContent selectedVariantId="variant-b" />);
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("TIER A DOC");
  expect(alerts).toContainEqual({
    message: "This page's content could not be displayed. Reload the page before editing it.",
    level: "error",
  });
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  getMountedEditor().emit("update", { editor: getMountedEditor(), transaction: null } as never);
  expect(tierB.rich_content[0]?.description).toEqual(poisonPage.description);
});

// Switch-back after a failed reset must not reopen writes before the recovery
// reset lands: the mounted doc may carry edits typed over the stale page.
it("keeps writes blocked on switch-back until the recovery reset lands", async () => {
  const pageA = makePage("page-a", "PAGE A");
  const poisonPage = {
    id: "page-b",
    title: null,
    description: { type: "doc", content: [{ type: "paragraph", content: [{ type: "text" }] }] },
    updated_at: "2026-01-01T00:00:00.000Z",
  };
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the poison doc is deliberately malformed
  const variant = { id: "variant-a", name: "A", rich_content: [pageA, poisonPage] } as unknown as VariantFixture;
  const product = buildProduct([variant]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  render(<ContentTabContent selectedVariantId="variant-a" />);
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("PAGE A");

  const pageTabs = document.querySelectorAll('[role="tab"]');
  act(() => {
    (pageTabs[1] instanceof HTMLElement ? pageTabs[1] : undefined)?.click();
  });
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("PAGE A");
  act(() => {
    getMountedEditor().chain().focus("end").insertContent(" STRAY").run();
  });
  act(() => {
    (document.querySelectorAll('[role="tab"]')[0] instanceof HTMLElement
      ? // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowed by the check above
        (document.querySelectorAll('[role="tab"]')[0] as HTMLElement)
      : undefined
    )?.click();
  });
  // Pre-reset window: the stray edits must not be stored into page A.
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  getMountedEditor().emit("update", { editor: getMountedEditor(), transaction: null } as never);
  expect(variant.rich_content[0]?.description).toEqual(pageA.description);

  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("PAGE A");
});
// "No page selected" and "reset pending" are distinct guard states: conflating
// them lets addPage copy the stale doc into an empty variant.
it("does not copy the stale doc into an empty variant during the switch window", async () => {
  const tierAPage = makePage("page-a", "TIER A DOC");
  const tierA: VariantFixture = { id: "variant-a", name: "A", rich_content: [tierAPage] };
  const emptyTier: VariantFixture = { id: "variant-b", name: "B", rich_content: [] };
  const product = buildProduct([tierA, emptyTier]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  const { rerender } = render(<ContentTabContent selectedVariantId="variant-a" />);
  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("TIER A DOC");

  rerender(<ContentTabContent selectedVariantId="variant-b" />);
  // Switch window: the mounted doc is still tier A's.
  // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- the update handler ignores its args
  getMountedEditor().emit("update", { editor: getMountedEditor(), transaction: null } as never);
  expect(emptyTier.rich_content).toHaveLength(0);

  await act(async () => {});
  expect(getMountedEditor().getText()).toBe("");
});
// PageTab's title editor never resets on prop changes: same-id pages across
// variants need a remount, and an in-progress rename must not carry over.
it("resets the rename editor across a variant switch between same-id pages", async () => {
  const tierAPage = makePage("shared-id", "TIER A DOC", "Alpha");
  const tierBPage = makePage("shared-id", "TIER B DOC", "Beta");
  // Two pages per variant so the page list renders.
  const tierA: VariantFixture = { id: "variant-a", name: "A", rich_content: [tierAPage, makePage("extra-a", "X")] };
  const tierB: VariantFixture = { id: "variant-b", name: "B", rich_content: [tierBPage, makePage("extra-b", "Y")] };
  const product = buildProduct([tierA, tierB]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  const { rerender, getByText, queryByText } = render(<ContentTabContent selectedVariantId="variant-a" />);
  await act(async () => {});
  expect(getByText("Alpha")).toBeTruthy();

  const menuTriggers = document.querySelectorAll('[role="tab"] button');
  act(() => {
    (menuTriggers[0] instanceof HTMLElement ? menuTriggers[0] : undefined)?.click();
  });
  await act(async () => {});
  const renameItem = getByText("Rename");
  act(() => {
    renameItem.click();
  });
  await act(async () => {});

  const titleEditor = document.querySelector('[role="tab"] .tiptap');
  expect(titleEditor?.textContent).toBe("Alpha");

  rerender(<ContentTabContent selectedVariantId="variant-b" />);
  await act(async () => {});

  expect(document.querySelector('[role="tab"] .tiptap')).toBeNull();
  expect(getByText("Beta")).toBeTruthy();
  expect(queryByText("Alpha")).toBeNull();

  const newTriggers = document.querySelectorAll('[role="tab"] button');
  act(() => {
    (newTriggers[0] instanceof HTMLElement ? newTriggers[0] : undefined)?.click();
  });
  await act(async () => {});
  act(() => {
    getByText("Rename").click();
  });
  await act(async () => {});
  expect(document.querySelector('[role="tab"] .tiptap')?.textContent).toBe("Beta");
});
