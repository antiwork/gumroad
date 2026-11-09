// @vitest-environment happy-dom
import { cleanup, render, act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import type { Editor } from "@tiptap/core";
import * as React from "react";
import { afterEach, assert, describe, expect, it, vi } from "vitest";

import { buildDeletionOperations } from "$app/data/product_save_contract";
import { cast } from "$app/utils/cast";
import { PICKED_FILE_SNAPSHOT_LIMIT_BYTES } from "$app/utils/snapshotPickedFile";

import { ContentTabContent, rawDocContainsNode } from "$app/components/ProductEdit/ContentTab";
import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { Product } from "$app/components/ProductEdit/state";

// Capture the real mounted TipTap editor so the test can fire an update inside
// the deferred page-switch window that editorContentPageIdRef guards (gp#1943).
let mountedEditor: Editor | null = null;

// vite.config.ts replaces the bare `SSR` identifier at build time.
Object.assign(globalThis, { SSR: false });

// The toolbar's `custom` slot holds the real entry points (link, upload, disable-downloads);
// it stays unrendered everywhere else so a toolbar item can't affect an unrelated assertion.
const toolbarCustom = vi.hoisted((): { render: boolean; openPopover: string | null } => ({
  render: false,
  openPopover: null,
}));

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
  deletedFileIds: new Set<string>(),
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
  const { Popover } = await import("$app/components/Popover");
  return {
    ...mod,
    useRichTextEditor: (options: Parameters<typeof mod.useRichTextEditor>[0]) => {
      const editor = mod.useRichTextEditor(options);
      mountedEditor = editor;
      return editor;
    },
    RichTextEditorToolbar: ({ custom }: { custom?: React.ReactNode }) => (toolbarCustom.render ? custom : null),
    // The sibling toolbar items need the toolbar's own tooltip context, which the mock drops, so
    // only the popover named in `openPopover` renders: its real menu, already open.
    PopoverMenuItem: ({ name, children }: { name: string; children: React.ReactNode }) =>
      toolbarCustom.openPopover === name ? <Popover open>{children}</Popover> : null,
    useImageUploadSettings: () => ({ isUploading: false, onUpload: () => {}, allowedExtensions: [] }),
  };
});

vi.mock("$app/components/ProductEdit/Layout", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/ProductEdit/Layout")>();
  return { ...mod, useProductUrl: () => "#" };
});
const scheduledUploads = vi.hoisted(
  (): { file: File; cancellationKey: string; onComplete: () => void; onError: () => void }[] => [],
);
const cancelUpload = vi.hoisted(() => vi.fn());
// Evaporate returns an error string instead of an index when it rejects a file up front.
const scheduleResult = vi.hoisted((): { value: string | number } => ({ value: 0 }));
vi.mock("$app/components/EvaporateUploader", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/EvaporateUploader")>();
  return {
    ...mod,
    useEvaporateUploader: () => ({
      scheduleUpload: ({
        file,
        cancellationKey,
        onComplete,
        onError,
      }: {
        file: File;
        cancellationKey: string;
        onComplete: () => void;
        onError: () => void;
      }) => {
        scheduledUploads.push({ file, cancellationKey, onComplete, onError });
        return scheduleResult.value;
      },
      cancelUpload,
    }),
  };
});
vi.mock("$app/components/S3UploadConfig", async (importOriginal) => {
  const mod = await importOriginal<typeof import("$app/components/S3UploadConfig")>();
  return {
    ...mod,
    useS3UploadConfig: () => ({ generateS3KeyForUpload: () => ({ s3key: "key", fileUrl: "url" }) }),
  };
});
const viewport = vi.hoisted(() => ({ isDesktop: true }));
vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => viewport.isDesktop }));
vi.mock("$app/components/ReviewForm", () => ({ ReviewForm: () => null }));
vi.mock("$app/components/UpsellSelectModal", () => ({ UpsellSelectModal: () => null }));
vi.mock("$app/components/TestimonialSelectModal", () => ({ TestimonialSelectModal: () => null }));
vi.mock("$app/components/ProductEdit/ContentTab/EpubNudge", () => ({ EpubNudge: () => null }));
const sortable = vi.hoisted(() => ({ echoList: false }));
vi.mock("react-sortablejs", () => ({
  default: ({ children }: { children: React.ReactNode }) => children,
  // Echo layout writes only in the switch-overwrite regression.
  // Preserve the container because Sortable uses raw child indices.
  ReactSortable: ({
    children,
    list,
    setList,
    tag: Tag = "div",
  }: {
    children: React.ReactNode;
    list: unknown[];
    setList: (next: unknown[]) => void;
    tag?: React.ElementType;
  }) => {
    React.useLayoutEffect(() => {
      if (sortable.echoList) setList(list);
    }, [list, setList]);
    return <Tag data-testid="sortable">{children}</Tag>;
  },
}));
const alerts = vi.hoisted((): { message: string; level: string }[] => []);
vi.mock("$app/components/server-components/Alert", () => ({
  showAlert: (message: string, level: string) => alerts.push({ message, level }),
}));

afterEach(() => {
  cleanup();
  mountedEditor = null;
  alerts.length = 0;
  scheduledUploads.length = 0;
  cancelUpload.mockReset();
  scheduleResult.value = 0;
  sortable.echoList = false;
  viewport.isDesktop = true;
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

// Deleting a page whose STORED id another page still carries must not record
// deletion intent: the shared id names the surviving page's row, and sending
// it would let the save delete content the seller kept (gumroad-private#2023).
// A unique id records as before.
it("skips recording a deleted page's id while another page still carries it", async () => {
  const impostor = makePage("shared-stored-id", "IMPOSTOR", "Impostor");
  const uniquePage = makePage("unique-id", "UNIQUE", "Unique");
  const realPage = makePage("shared-stored-id", "REAL", "Real");
  const paidVariant: VariantFixture = { id: "variant-paid", name: "Paid", rich_content: [impostor, uniquePage] };
  const freeVariant: VariantFixture = { id: "variant-free", name: "Free", rich_content: [realPage] };
  const product = buildProduct([paidVariant, freeVariant]);

  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  const { getByText } = render(<ContentTabContent selectedVariantId="variant-paid" />);
  await act(async () => {});

  const deletePageAt = async (rowIndex: number) => {
    const triggers = document.querySelectorAll('[role="tab"] button');
    act(() => {
      (triggers[rowIndex] instanceof HTMLElement ? triggers[rowIndex] : undefined)?.click();
    });
    await act(async () => {});
    act(() => {
      getByText("Delete").click();
    });
    await act(async () => {});
    act(() => {
      getByText("Yes, delete").click();
    });
    await act(async () => {});
  };

  // The impostor shares its stored id with the real page in the other
  // variant: deleting it must record nothing.
  await deletePageAt(0);
  expect(product.confirmed_removed_rich_content_ids ?? []).toEqual([]);
  expect(paidVariant.rich_content.map(({ id }) => id)).toEqual(["unique-id"]);

  // The unique page records normally.
  await deletePageAt(0);
  expect(product.confirmed_removed_rich_content_ids).toEqual(["unique-id"]);
  expect(paidVariant.rich_content).toEqual([]);
});

// Sortable writes `list` back during layout. A stale pagesRef would then
// treat that report as the previous variant's membership and overwrite
// the newly selected tier (gp#2023).
it("keeps the newly selected variant's pages when Sortable reports during the switch", async () => {
  const freePage = makePage("page-free", "FREE DOC", "Freepass");
  const paidMag = makePage("page-paid-mag", "ISSUE 40", "TischLog Mag");
  const paidExtras = makePage("page-paid-extras", "BONUS", "Extras");
  const freeVariant: VariantFixture = { id: "variant-free", name: "Creator Freepass", rich_content: [freePage] };
  const paidVariant: VariantFixture = {
    id: "variant-paid",
    name: "Insight Collector",
    rich_content: [paidMag, paidExtras],
  };
  const product = buildProduct([freeVariant, paidVariant]);

  sortable.echoList = true;
  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  const { rerender } = render(<ContentTabContent selectedVariantId="variant-free" />);
  await act(async () => {});
  expect(paidVariant.rich_content.map(({ id, title }) => ({ id, title }))).toEqual([
    { id: "page-paid-mag", title: "TischLog Mag" },
    { id: "page-paid-extras", title: "Extras" },
  ]);

  rerender(<ContentTabContent selectedVariantId="variant-paid" />);
  await act(async () => {});

  expect(paidVariant.rich_content.map(({ id, title }) => ({ id, title }))).toEqual([
    { id: "page-paid-mag", title: "TischLog Mag" },
    { id: "page-paid-extras", title: "Extras" },
  ]);
  expect(freeVariant.rich_content.map(({ id }) => id)).toEqual(["page-free"]);
});

// Shared raw ids overlap, so the disjoint-id guard does not fire. Only a
// current pagesRef keeps extra-b and drops extra-a (gp#2023).
it("keeps the newly selected variant's pages when a raw id is shared across tiers", async () => {
  const tierA: VariantFixture = {
    id: "variant-a",
    name: "A",
    rich_content: [makePage("shared-id", "TIER A DOC", "Alpha"), makePage("extra-a", "A EXTRA", "A extra")],
  };
  const tierB: VariantFixture = {
    id: "variant-b",
    name: "B",
    rich_content: [makePage("shared-id", "TIER B DOC", "Beta"), makePage("extra-b", "B EXTRA", "B extra")],
  };
  const product = buildProduct([tierA, tierB]);

  sortable.echoList = true;
  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };

  const { rerender } = render(<ContentTabContent selectedVariantId="variant-a" />);
  await act(async () => {});

  rerender(<ContentTabContent selectedVariantId="variant-b" />);
  await act(async () => {});

  expect(tierB.rich_content.map(({ id, title }) => ({ id, title }))).toEqual([
    { id: "shared-id", title: "Beta" },
    { id: "extra-b", title: "B extra" },
  ]);
  expect(tierA.rich_content.map(({ id, title }) => ({ id, title }))).toEqual([
    { id: "shared-id", title: "Alpha" },
    { id: "extra-a", title: "A extra" },
  ]);
});

const attachToolbarFiles = (input: HTMLInputElement, picked: File[]) => {
  const valueWrites: string[] = [];
  Object.defineProperty(input, "files", {
    configurable: true,
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- minimal FileList for the handler
    value: {
      ...picked,
      length: picked.length,
      item: (index: number) => picked[index] ?? null,
      [Symbol.iterator]: () => picked[Symbol.iterator](),
    } as unknown as FileList,
  });
  Object.defineProperty(input, "value", {
    configurable: true,
    get: () => "",
    set: (value: string) => valueWrites.push(value),
  });
  return valueWrites;
};

const attachToolbarFile = (input: HTMLInputElement, picked: File) => attachToolbarFiles(input, [picked]);

const renderToolbarPicker = async () => {
  const product = buildProduct([{ id: "variant-a", name: "A", rich_content: [makePage("page-1", "PAGE")] }]);
  context.product = product;
  context.updateProduct = (update: unknown) => {
    // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
    if (typeof update === "function") (update as (p: Product) => void)(product);
    else Object.assign(product, update);
  };
  render(<ContentTabContent selectedVariantId="variant-a" />);
  await act(async () => {});
  const input = document.querySelector<HTMLInputElement>('input[name="file"]');
  if (!input) throw new Error("Toolbar file input did not mount");
  return { product, input };
};

it("uploads a snapshot copy of a small picked file and resets the toolbar input", async () => {
  const { input } = await renderToolbarPicker();
  const picked = new File(["file-bytes"], "notes.txt", { type: "text/plain" });
  const valueWrites = attachToolbarFile(input, picked);

  await act(async () => {
    fireEvent.change(input);
  });

  const uploaded = scheduledUploads[0]?.file;
  if (!uploaded) throw new Error("No upload was scheduled");
  // A copy must be uploaded, not the picked File: resetting the input revokes the
  // original's backing in Chromium, stranding the upload at 0%.
  expect(uploaded).not.toBe(picked);
  expect(uploaded.name).toBe("notes.txt");
  expect(await uploaded.text()).toBe("file-bytes");
  expect(valueWrites).toEqual([""]);
});

const pickedVideos = (names: string[]) => names.map((name) => new File(["x"], name, { type: "video/mp4" }));

const fileEmbedGroupOrder = () => {
  const groups: string[][] = [];
  getMountedEditor().state.doc.forEach((node) => {
    if (node.type.name !== "fileEmbedGroup") return;
    const ids: string[] = [];
    node.forEach((child) => ids.push(String(child.attrs.id)));
    groups.push(ids);
  });
  return groups;
};

it("keeps the page order when the seller uploads files in several batches", async () => {
  const { product, input } = await renderToolbarPicker();

  for (const batch of [
    ["a1.mp4", "a2.mp4", "a3.mp4"],
    ["b1.mp4", "b2.mp4", "b3.mp4"],
  ]) {
    attachToolbarFiles(input, pickedVideos(batch));
    await act(async () => {
      fireEvent.change(input);
    });
  }

  // product.files is appended in pick order, so the page must list the batches in that order.
  expect(fileEmbedGroupOrder().flat()).toEqual(product.files.map((file) => file.id));
});

const docShape = () => {
  const parts: string[] = [];
  getMountedEditor().state.doc.forEach((node) => {
    if (node.type.name === "fileEmbedGroup") {
      const ids: string[] = [];
      node.forEach((child) => ids.push(String(child.attrs.id)));
      parts.push(`group(${ids.length})`);
    } else if (node.type.name === "fileEmbed") parts.push("file");
    else parts.push(node.type.name);
  });
  return parts;
};

const pickedEmbedIds = () => {
  const ids: string[] = [];
  getMountedEditor().state.doc.forEach((node) => {
    if (node.type.name === "fileEmbedGroup") node.forEach((child) => ids.push(String(child.attrs.id)));
    else if (node.type.name === "fileEmbed") ids.push(String(node.attrs.id));
  });
  return ids;
};

it("keeps the page order when the batches are picked with the caret inside the text", async () => {
  const { product, input } = await renderToolbarPicker();
  // A block inserted inside a paragraph splits it, so the group does not land at the caret position.
  getMountedEditor().commands.setTextSelection(2);

  for (const batch of [
    ["a1.mp4", "a2.mp4", "a3.mp4"],
    ["b1.mp4", "b2.mp4", "b3.mp4"],
  ]) {
    attachToolbarFiles(input, pickedVideos(batch));
    await act(async () => {
      fireEvent.change(input);
    });
  }

  expect(fileEmbedGroupOrder()).toEqual([
    product.files.slice(0, 3).map((file) => file.id),
    product.files.slice(3).map((file) => file.id),
  ]);
});

it("keeps a file picked after a batch below that batch when the caret is inside the text", async () => {
  const { product, input } = await renderToolbarPicker();
  getMountedEditor().commands.setTextSelection(2);

  attachToolbarFiles(input, pickedVideos(["a1.mp4", "a2.mp4", "a3.mp4"]));
  await act(async () => {
    fireEvent.change(input);
  });
  attachToolbarFile(input, new File(["x"], "b.mp4", { type: "video/mp4" }));
  await act(async () => {
    fireEvent.change(input);
  });

  expect(docShape()).toEqual(["paragraph", "group(3)", "file", "paragraph"]);
  expect(pickedEmbedIds()).toEqual(product.files.map((file) => file.id));
});

it("keeps the page order when the seller uploads one file at a time", async () => {
  const { product, input } = await renderToolbarPicker();

  for (const name of ["a.mp4", "b.mp4", "c.mp4"]) {
    attachToolbarFile(input, new File(["x"], name, { type: "video/mp4" }));
    await act(async () => {
      fireEvent.change(input);
    });
  }

  const embedded: string[] = [];
  getMountedEditor().state.doc.forEach((node) => {
    if (node.type.name === "fileEmbed") embedded.push(String(node.attrs.id));
  });
  expect(embedded).toEqual(product.files.map((file) => file.id));
});

it("does not reset an over-budget pick until Evaporate completes", async () => {
  const { input } = await renderToolbarPicker();
  const picked = new File(["x"], "huge.mp4", { type: "video/mp4" });
  Object.defineProperty(picked, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
  const valueWrites = attachToolbarFile(input, picked);

  await act(async () => {
    fireEvent.change(input);
  });

  const uploaded = scheduledUploads[0];
  if (!uploaded) throw new Error("No upload was scheduled");
  expect(uploaded.file).toBe(picked);
  expect(valueWrites).toEqual([]);

  await act(async () => {
    uploaded.onComplete();
  });
  expect(valueWrites).toEqual([""]);
});

it("marks the row failed and tells the seller when an upload errors out", async () => {
  const { product, input } = await renderToolbarPicker();
  attachToolbarFile(input, new File(["x"], "huge.zip", { type: "application/zip" }));

  await act(async () => {
    fireEvent.change(input);
  });

  const upload = scheduledUploads[0];
  const scheduled = product.files.at(-1);
  if (!upload) throw new Error("No upload was scheduled");
  if (!scheduled) throw new Error("Picked file was not added");
  expect(upload.cancellationKey).toBe(`file_${scheduled.id}`);

  await act(async () => {
    upload.onError();
  });

  // A failed upload has to stop counting as in-flight, or Save changes stays
  // disabled for the rest of the session.
  expect(scheduled.status.type === "unsaved" && scheduled.status.uploadStatus.type).toBe("failed");
  expect(alerts).toEqual([
    { message: 'Could not upload huge.zip. Select "Upload again" on the file to retry.', level: "error" },
  ]);
  expect(cancelUpload).toHaveBeenCalledWith(`file_${scheduled.id}`);
});

it("restarts a failed upload in place with the file the seller picks again", async () => {
  const { product, input } = await renderToolbarPicker();
  attachToolbarFile(input, new File(["x"], "huge.zip", { type: "application/zip" }));
  await act(async () => {
    fireEvent.change(input);
  });
  const failed = product.files.at(-1);
  if (!failed) throw new Error("Picked file was not added");
  await act(async () => {
    scheduledUploads[0]?.onError();
  });

  // Set while it was uploading: the retry keeps the description but drops what fit the old file type.
  Object.assign(failed, { description: "Field notes", isbn: "978-3-16-148410-0", pdf_stamp_enabled: true });

  const fileEmbed = getMountedEditor().extensionManager.extensions.find((ext) => ext.name === FileEmbed.name);
  const onRetryUpload = fileEmbed?.options.getConfig?.()?.onRetryUpload;
  if (!onRetryUpload) throw new Error("FileEmbed retry hook was not wired");
  const repicked = new File(["xy"], "huge-v2.zip", { type: "application/zip" });
  const retryInput = document.createElement("input");
  retryInput.type = "file";
  attachToolbarFile(retryInput, repicked);
  await act(async () => {
    onRetryUpload(failed.id, retryInput);
  });

  // Same id, so every embed of the file keeps its place in the content.
  const retried = product.files.find((file) => file.id === failed.id);
  expect(product.files).toHaveLength(1);
  expect(scheduledUploads[1]?.cancellationKey).toBe(`file_${failed.id}`);
  // A small pick is copied first, like the toolbar's, so the handle can be released.
  expect(scheduledUploads[1]?.file).not.toBe(repicked);
  expect(scheduledUploads[1]?.file.name).toBe("huge-v2.zip");
  expect(retried).toMatchObject({ display_name: "huge-v2", file_size: 2, description: "Field notes" });
  expect(retried?.isbn).toBeUndefined();
  expect(retried?.pdf_stamp_enabled).toBe(false);
  expect(retried?.status.type === "unsaved" && retried.status.uploadStatus.type).toBe("uploading");

  await act(async () => {
    scheduledUploads[1]?.onComplete();
  });
  const completed = product.files.find((file) => file.id === failed.id);
  expect(completed?.status.type === "unsaved" && completed.status.uploadStatus.type).toBe("uploaded");
});

it("marks the row failed when Evaporate rejects the file up front", async () => {
  const { product, input } = await renderToolbarPicker();
  scheduleResult.value = "The file is too large.";
  attachToolbarFile(input, new File(["x"], "huge.zip", { type: "application/zip" }));

  await act(async () => {
    fireEvent.change(input);
  });

  // Nothing will ever report progress for it, so leaving it "uploading" would block Save for good.
  const rejected = product.files.at(-1);
  expect(rejected?.status.type === "unsaved" && rejected.status.uploadStatus.type).toBe("failed");
  expect(alerts).toEqual([{ message: "The file is too large.", level: "error" }]);
});

it("resets an over-budget pick when the seller cancels the upload", async () => {
  const { product, input } = await renderToolbarPicker();
  const picked = new File(["x"], "huge.mp4", { type: "video/mp4" });
  Object.defineProperty(picked, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
  const valueWrites = attachToolbarFile(input, picked);

  await act(async () => {
    fireEvent.change(input);
  });
  expect(valueWrites).toEqual([]);

  const fileId = product.files.at(-1)?.id;
  if (!fileId) throw new Error("Picked file was not added");
  const fileEmbed = getMountedEditor().extensionManager.extensions.find((ext) => ext.name === FileEmbed.name);
  const onUploadCancelled = fileEmbed?.options.getConfig?.()?.onUploadCancelled;
  if (!onUploadCancelled) throw new Error("FileEmbed cancel hook was not wired");

  await act(async () => {
    onUploadCancelled(fileId);
  });
  expect(valueWrites).toEqual([""]);
});

it("ignores a second toolbar pick while an over-budget upload still needs the input", async () => {
  const { input } = await renderToolbarPicker();
  const first = new File(["x"], "huge.mp4", { type: "video/mp4" });
  Object.defineProperty(first, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
  const valueWrites = attachToolbarFile(input, first);

  await act(async () => {
    fireEvent.change(input);
  });
  expect(scheduledUploads).toHaveLength(1);
  expect(scheduledUploads[0]?.file).toBe(first);
  expect(input.disabled).toBe(true);
  expect(valueWrites).toEqual([]);

  await act(async () => {
    fireEvent.change(input);
  });
  expect(scheduledUploads).toHaveLength(1);
  expect(scheduledUploads[0]?.file).toBe(first);

  await act(async () => {
    scheduledUploads[0]?.onComplete();
  });
  expect(valueWrites).toEqual([""]);
  expect(input.disabled).toBe(false);
});
it("ignores a second toolbar pick while a mixed pick is still snapshotting", async () => {
  const waiters: { file: File; resolve: (buffer: ArrayBuffer) => void }[] = [];
  const originalArrayBuffer = File.prototype.arrayBuffer;
  File.prototype.arrayBuffer = function (this: File) {
    return new Promise((resolve) => {
      waiters.push({ file: this, resolve });
    });
  };

  try {
    const { input } = await renderToolbarPicker();
    const small = new File(["abc"], "notes.txt", { type: "text/plain" });
    const large = new File(["x"], "huge.mp4", { type: "video/mp4" });
    Object.defineProperty(large, "size", { value: PICKED_FILE_SNAPSHOT_LIMIT_BYTES + 1 });
    const valueWrites = attachToolbarFiles(input, [small, large]);

    fireEvent.change(input);
    expect(waiters).toHaveLength(1);
    expect(input.disabled).toBe(true);
    expect(scheduledUploads).toHaveLength(0);

    await act(async () => {
      fireEvent.change(input);
    });
    expect(waiters).toHaveLength(1);
    expect(scheduledUploads).toHaveLength(0);

    await act(async () => {
      for (const waiter of waiters) {
        waiter.resolve(await originalArrayBuffer.call(waiter.file));
      }
    });
    expect(scheduledUploads).toHaveLength(2);
    expect(scheduledUploads[0]?.file).not.toBe(small);
    expect(scheduledUploads[1]?.file).toBe(large);
    expect(valueWrites).toEqual([]);

    await act(async () => {
      scheduledUploads[0]?.onComplete();
      scheduledUploads[1]?.onComplete();
    });
    expect(valueWrites).toEqual([""]);
    expect(input.disabled).toBe(false);
  } finally {
    File.prototype.arrayBuffer = originalArrayBuffer;
  }
});

it("keeps the mobile page-list summary row out of the Sortable's container", async () => {
  viewport.isDesktop = false;
  const product = buildProduct([
    { id: "variant-paid", name: "Paid", rich_content: [makePage("page-a", "PAGE A"), makePage("page-b", "PAGE B")] },
  ]);
  context.product = product;

  render(<ContentTabContent selectedVariantId="variant-paid" />);
  await act(async () => {});

  const summaryButton = [...document.querySelectorAll("button")].find((button) =>
    button.textContent?.includes("Table of contents:"),
  );
  assert(summaryButton, "The mobile page-list summary is rendered");
  expect(document.querySelector('[data-testid="sortable"]')).toBeNull();

  await act(async () => {
    fireEvent.click(summaryButton);
  });

  const list = document.querySelector('[data-testid="sortable"]');
  expect(list).not.toBeNull();
  expect(document.body.textContent).toContain("Table of contents:");
  expect(list?.textContent).not.toContain("Table of contents:");
  expect(list?.querySelectorAll('[role="tab"]')).toHaveLength(2);
});

// The result of the bulk disable-downloads action belongs to the content tab, so it is asserted
// through the real toolbar entry point — a broken callback wiring or Dismiss would fail here.
const requestResponses = vi.hoisted((): unknown[] => []);
vi.mock("$app/utils/request", () => ({
  request: () => Promise.resolve({ ok: true, json: () => Promise.resolve(requestResponses.shift()) }),
  ResponseError: class ResponseError extends Error {},
}));
// The toolbar's link item renders only inside the custom slot, where it has no toolbar context.
vi.mock("$app/components/TiptapExtensions/Link", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/components/TiptapExtensions/Link")>()),
  LinkMenuItem: () => null,
}));

it("shows the bulk disable-downloads result in flow and lets the seller dismiss it", async () => {
  Object.assign(globalThis, {
    Routes: {
      disable_downloads_for_all_files_link_path: (permalink: string) =>
        `/links/${permalink}/disable_downloads_for_all_files`,
    },
  });
  toolbarCustom.render = true;
  context.product = buildProduct([{ id: "variant-paid", name: "Paid", rich_content: [] }]);
  requestResponses.push({ disabled_count: 2, disabled_file_ids: [], ineligible_count: 1 });

  try {
    render(<ContentTabContent selectedVariantId="variant-paid" />);
    await act(async () => {});

    fireEvent.click(await screen.findByRole("button", { name: "Disable all downloads" }));
    fireEvent.click(await screen.findByRole("button", { name: "Yes, disable downloads" }));

    const result = await screen.findByRole("status");
    expect(result.textContent).toContain("Downloads are now off for 2 files.");
    expect(result.textContent).toContain("1 file stays downloadable");

    fireEvent.click(screen.getByRole("button", { name: "Dismiss" }));
    await waitFor(() => expect(screen.queryByRole("status")).toBeNull());
  } finally {
    toolbarCustom.render = false;
  }
});

describe("removing a file from the product", () => {
  const file = (id: string, display_name: string, url: string) => ({
    id,
    display_name,
    description: null,
    extension: "PDF",
    file_size: 1024,
    is_pdf: true,
    pdf_stamp_enabled: false,
    hide_kindle_and_read_buttons: false,
    is_streamable: false,
    stream_only: false,
    is_transcoding_in_progress: false,
    url,
    subtitle_files: [],
    status: { type: "saved" as const },
    thumbnail: null,
  });
  const embedPage = (id: string, fileId: string) =>
    cast<ReturnType<typeof makePage>>({
      id,
      title: null,
      description: {
        type: "doc",
        content: [
          { type: "fileEmbed", attrs: { id: fileId, uid: `${fileId}-uid` } },
          { type: "paragraph", content: [{ type: "text", text: `Page ${id}` }] },
        ],
      },
      updated_at: "2026-01-01T00:00:00.000Z",
    });
  const embeddedFileIds = (node: unknown): unknown[] => {
    if (typeof node !== "object" || node === null) return [];
    const { type, attrs, content } = cast<{ type?: string; attrs?: { id?: unknown }; content?: unknown[] }>(node);
    return [...(type === "fileEmbed" ? [attrs?.id] : []), ...(content ?? []).flatMap(embeddedFileIds)];
  };

  const workbook = file("file-workbook", "Workbook", "https://example.com/workbook.pdf");
  const workbookCopy = file("file-workbook-copy", "Workbook", "https://example.com/workbook.pdf");
  const orphan = file("file-orphan", "Orphan", "https://example.com/orphan.pdf");

  const mount = async () => {
    const product = buildProduct([
      { id: "version-a", name: "A", rich_content: [embedPage("page-a", workbook.id)] },
      { id: "version-b", name: "B", rich_content: [embedPage("page-b", workbookCopy.id)] },
    ]);
    product.files = [workbook, workbookCopy, orphan];
    context.product = product;
    // A fresh product per write, as the page's state does, so memoized reads see the change.
    context.updateProduct = (update: unknown) => {
      const next = { ...cast<Product>(context.product) };
      // eslint-disable-next-line @typescript-eslint/consistent-type-assertions -- narrowing the update union for the fixture
      if (typeof update === "function") (update as (p: Product) => void)(next);
      else Object.assign(next, update);
      context.product = next;
    };
    context.filesById = new Map(product.files.map((entry) => [entry.id, entry]));
    Object.assign(globalThis, {
      Routes: {
        internal_product_existing_product_files_path: () => "/existing_product_files",
        download_product_files_path: () => "/download",
      },
    });
    const library = [
      { ...workbook, attached_product_name: "Product" },
      { ...orphan, attached_product_name: "Product" },
      { ...file("file-elsewhere", "Elsewhere", "https://example.com/elsewhere.pdf"), attached_product_name: "Other" },
    ];
    Object.assign(context, { existingFiles: library });
    requestResponses.push({ existing_files: library });
    toolbarCustom.render = true;
    toolbarCustom.openPopover = "Upload files";

    const view = render(<ContentTabContent selectedVariantId="version-b" />);
    await act(async () => {});
    return {
      current: () => cast<Product>(context.product),
      rerender: () => view.rerender(<ContentTabContent selectedVariantId="version-b" />),
    };
  };
  const openPicker = async () => {
    fireEvent.click(screen.getByRole("menuitem", { name: "Existing product files" }));
    await screen.findByRole("option", { name: /Orphan/u });
  };
  const status = (product: Product, id: string) => product.files.find((entry) => entry.id === id)?.status;

  afterEach(() => {
    toolbarCustom.render = false;
    toolbarCustom.openPopover = null;
    context.filesById = new Map();
    context.deletedFileIds = new Set();
    Object.assign(context, { existingFiles: [], fileIdMappings: {} });
  });

  it("takes back a block that undo restores for a file a save already deleted", async () => {
    const { current, rerender } = await mount();
    act(() => {
      getMountedEditor().chain().setNodeSelection(0).deleteSelection().run();
    });
    // What a save that spent the removal leaves behind.
    context.updateProduct((product: Product) => {
      product.files = product.files.filter((entry) => entry.id !== workbookCopy.id);
    });
    context.deletedFileIds = new Set([workbookCopy.id]);
    rerender();

    await act(async () => {
      getMountedEditor().commands.undo();
      await Promise.resolve();
    });

    expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual([]);
    expect(embeddedFileIds(current().variants[1]?.rich_content[0]?.description ?? {})).toEqual([]);
    expect(alerts).toContainEqual({
      message: "This file was deleted from the product when you saved. Upload it again to add it back.",
      level: "warning",
    });
  });

  const deleteWorkbookCopyAndSave = (current: () => Product, rerender: () => void) => {
    act(() => {
      getMountedEditor().chain().setNodeSelection(0).deleteSelection().run();
    });
    // What a save that spent the removal leaves behind.
    context.updateProduct((product: Product) => {
      product.files = product.files.filter((entry) => entry.id !== workbookCopy.id);
    });
    context.filesById = new Map(current().files.map((entry) => [entry.id, entry]));
    context.deletedFileIds = new Set([workbookCopy.id]);
    rerender();
  };

  it.each([
    ["a file of this product", "https://example.com/workbook.pdf"],
    ["another product's file", "https://example.com/elsewhere.pdf"],
  ])(
    "takes back a pasted block for a file a save deleted, rather than resolving it to %s with the same url",
    async (_case, url) => {
      const { current, rerender } = await mount();
      deleteWorkbookCopyAndSave(current, rerender);

      await act(async () => {
        getMountedEditor().view.pasteHTML(`<file-embed id="${workbookCopy.id}" url="${url}"></file-embed>`);
        await Promise.resolve();
      });

      expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual([]);
      expect(embeddedFileIds(current().variants[1]?.rich_content[0]?.description ?? {})).toEqual([]);
      expect(current().files.map((entry) => entry.id)).toEqual([workbook.id, orphan.id]);
      expect(alerts).toContainEqual({
        message: "This file was deleted from the product when you saved. Upload it again to add it back.",
        level: "warning",
      });
    },
  );

  it("places a library file whose copy on this product a save deleted", async () => {
    // A save that attaches another product's file maps that file's id to the copy it makes here.
    Object.assign(context, { fileIdMappings: { "file-elsewhere": "file-elsewhere-copy" } });
    context.deletedFileIds = new Set(["file-elsewhere-copy"]);
    const { current } = await mount();
    await openPicker();

    fireEvent.click(screen.getByRole("heading", { name: "Elsewhere" }));
    fireEvent.click(screen.getByRole("button", { name: "Select" }));
    await act(async () => {});

    // Placed under a fresh id, so the mapping to the deleted copy cannot claim it.
    const placed = current().files.find((entry) => entry.display_name === "Elsewhere");
    expect(placed?.id).not.toBe("file-elsewhere");
    expect(placed?.url).toBe("https://example.com/elsewhere.pdf");
    expect(embeddedFileIds(getMountedEditor().getJSON())).toContain(placed?.id);
    expect(alerts).toEqual([]);
  });

  it("places a block pasted from a library file's product after a save deleted its copy here", async () => {
    Object.assign(context, { fileIdMappings: { "file-elsewhere": "file-elsewhere-copy" } });
    context.deletedFileIds = new Set(["file-elsewhere-copy"]);
    const { current } = await mount();

    await act(async () => {
      getMountedEditor().view.pasteHTML(
        '<file-embed id="file-elsewhere" url="https://example.com/elsewhere.pdf"></file-embed>',
      );
      await Promise.resolve();
    });

    expect(embeddedFileIds(current().variants[1]?.rich_content[0]?.description ?? {})).toContain("file-elsewhere");
    expect(current().files.map((entry) => entry.id)).toContain("file-elsewhere");
    expect(alerts).toEqual([]);
  });

  it("keeps a pasted library file's block when the tab mounts after a save deleted its copy", async () => {
    // A block pasted from the library file's product attaches it again under its own id; only its first
    // copy was mapped and deleted.
    Object.assign(context, { fileIdMappings: { [workbookCopy.id]: "file-workbook-copy-copy" } });
    context.deletedFileIds = new Set(["file-workbook-copy-copy"]);
    const { current } = await mount();

    act(() => {
      getMountedEditor().chain().focus("end").insertContent("More").run();
    });

    expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual([workbookCopy.id]);
    expect(embeddedFileIds(current().variants[1]?.rich_content[0]?.description ?? {})).toEqual([workbookCopy.id]);
  });

  it("takes back a block undo restores under a library file's id after a save deleted its copy here", async () => {
    // The block left the page while the save that copied the library file ran, and a later save deleted the copy.
    Object.assign(context, { fileIdMappings: { "file-elsewhere": "file-elsewhere-copy" } });
    context.deletedFileIds = new Set(["file-elsewhere-copy"]);
    const { current } = await mount();

    await act(async () => {
      getMountedEditor().commands.insertContentAt(0, { type: "fileEmbed", attrs: { id: "file-elsewhere" } });
      await Promise.resolve();
    });

    expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual([workbookCopy.id]);
    expect(embeddedFileIds(current().variants[1]?.rich_content[0]?.description ?? {})).toEqual([workbookCopy.id]);
    expect(alerts).toContainEqual({
      message: "This file was deleted from the product when you saved. Upload it again to add it back.",
      level: "warning",
    });
  });

  it("takes back a restored block that still carries the id the file had before a save mapped it", async () => {
    Object.assign(context, { fileIdMappings: { "client-workbook": workbookCopy.id } });
    const { current, rerender } = await mount();
    deleteWorkbookCopyAndSave(current, rerender);

    // History can hold the block under its upload id when it left the page while the mapping save ran.
    await act(async () => {
      getMountedEditor().commands.insertContentAt(0, { type: "fileEmbed", attrs: { id: "client-workbook" } });
      await Promise.resolve();
    });

    expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual([]);
    expect(embeddedFileIds(current().variants[1]?.rich_content[0]?.description ?? {})).toEqual([]);
    expect(alerts).toContainEqual({
      message: "This file was deleted from the product when you saved. Upload it again to add it back.",
      level: "warning",
    });
  });

  it("takes back a restored block whose upload id maps through a copy a later save stored anew", async () => {
    // The first copy was restored while its deleting save ran, so the next save stored it again as the
    // copy that was then deleted.
    Object.assign(context, {
      fileIdMappings: { "client-workbook": "file-workbook-first-copy", "file-workbook-first-copy": workbookCopy.id },
    });
    const { current, rerender } = await mount();
    deleteWorkbookCopyAndSave(current, rerender);

    await act(async () => {
      getMountedEditor().commands.insertContentAt(0, { type: "fileEmbed", attrs: { id: "client-workbook" } });
      await Promise.resolve();
    });

    expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual([]);
    expect(embeddedFileIds(current().variants[1]?.rich_content[0]?.description ?? {})).toEqual([]);
    expect(alerts).toContainEqual({
      message: "This file was deleted from the product when you saved. Upload it again to add it back.",
      level: "warning",
    });
  });

  it.each([
    ["an upload", "blob:https://example.com/workbook"],
    ["a Dropbox file", "/products/product-id/files/download?product_file_ids%5B%5D=client-workbook"],
  ])("takes back a restored block of %s that was dragged before a save mapped its id", async (_case, url) => {
    Object.assign(context, { fileIdMappings: { "client-workbook": workbookCopy.id } });
    const { current, rerender } = await mount();
    deleteWorkbookCopyAndSave(current, rerender);

    // A drag leaves the file's url on the block, the same marker a paste from another product carries.
    await act(async () => {
      getMountedEditor().commands.insertContentAt(0, { type: "fileEmbed", attrs: { id: "client-workbook", url } });
      await Promise.resolve();
    });

    expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual([]);
    expect(alerts).toContainEqual({
      message: "This file was deleted from the product when you saved. Upload it again to add it back.",
      level: "warning",
    });
  });

  it("removes a file when the seller deletes its last block, and keeps it when the block comes back", async () => {
    const { current } = await mount();

    act(() => {
      getMountedEditor().chain().setNodeSelection(0).deleteSelection().run();
    });
    expect(buildDeletionOperations(current()).deleted_ids.files).toEqual([workbookCopy.id]);
    expect(status(current(), workbook.id)).toEqual({ type: "saved" });

    act(() => {
      getMountedEditor().commands.undo();
    });
    expect(status(current(), workbookCopy.id)).toEqual({ type: "saved" });
    expect(buildDeletionOperations(current()).deleted_ids.files).toBeUndefined();
  });

  it("lists a file no page embeds, and removes it", async () => {
    const { current, rerender } = await mount();

    const notice = screen.getByRole("status");
    expect(notice.textContent).toContain("This file is attached to this product but not on any page.");
    expect(within(notice).queryByRole("button", { name: /Workbook/u })).toBeNull();

    fireEvent.click(within(notice).getByRole("button", { name: "Remove Orphan from this product" }));
    expect(buildDeletionOperations(current()).deleted_ids.files).toEqual([orphan.id]);
    rerender();
    expect(screen.queryByText(/not on any page/u)).toBeNull();
  });

  it("puts a file no page embeds on the open page", async () => {
    const { current, rerender } = await mount();

    fireEvent.click(screen.getByRole("button", { name: "Add Orphan to this page" }));

    expect(embeddedFileIds(getMountedEditor().getJSON())).toContain(orphan.id);
    expect(current().files.filter((entry) => entry.id === orphan.id)).toHaveLength(1);
    rerender();
    expect(screen.queryByText(/not on any page/u)).toBeNull();
  });

  it("offers no removal in the picker, and picks a file when the seller clicks its name", async () => {
    await mount();
    await openPicker();

    expect(within(screen.getByRole("listbox")).queryAllByRole("button")).toHaveLength(0);
    fireEvent.click(screen.getByRole("heading", { name: "Orphan" }));
    expect(screen.getByRole("option", { name: /Orphan/u }).querySelector("input[type=checkbox]")).toHaveProperty(
      "checked",
      true,
    );
  });

  it("places a picked file no page shows as itself, and re-attaches one a page already shows", async () => {
    const { current } = await mount();
    await openPicker();

    fireEvent.click(screen.getByRole("heading", { name: "Orphan" }));
    fireEvent.click(screen.getByRole("heading", { name: "Workbook" }));
    fireEvent.click(screen.getByRole("button", { name: "Select" }));

    const files = current().files;
    expect(files.filter((entry) => entry.id === orphan.id)).toHaveLength(1);
    const workbooks = files.filter((entry) => entry.display_name === "Workbook").map((entry) => entry.id);
    expect(workbooks).toHaveLength(3);
    const reattached = workbooks.find((id) => id !== workbook.id && id !== workbookCopy.id);
    expect(embeddedFileIds(getMountedEditor().getJSON())).toEqual(
      expect.arrayContaining([workbookCopy.id, orphan.id, reattached]),
    );
  });
});
