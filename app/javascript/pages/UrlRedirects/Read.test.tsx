// @vitest-environment happy-dom

import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import Read, { canResumePdfFromLocation, downloadEpubArchive } from "./Read";

const mocks = vi.hoisted(() => ({
  createEpub: vi.fn(),
  trackMediaLocationChanged: vi.fn(),
  usePage: vi.fn(),
}));

vi.mock("@inertiajs/react", () => ({ usePage: mocks.usePage }));
vi.mock("$app/data/media_location", () => ({ trackMediaLocationChanged: mocks.trackMediaLocationChanged }));
vi.mock("epubjs", () => ({ default: mocks.createEpub }));

type Listener = (...args: unknown[]) => void;

const buildEpubHarness = () => {
  const listeners = new Map<string, Set<Listener>>();
  const emit = (type: string, ...args: unknown[]) => {
    for (const listener of listeners.get(type) ?? []) listener(...args);
  };
  const on = vi.fn((type: string, listener: Listener) => {
    const typeListeners = listeners.get(type) ?? new Set<Listener>();
    typeListeners.add(listener);
    listeners.set(type, typeListeners);
  });
  const off = vi.fn((type: string, listener: Listener) => listeners.get(type)?.delete(listener));
  const location = {
    start: { index: 4, cfi: "epubcfi(/6/10!/4/2/1:0)", displayed: { page: 1, total: 2 } },
    end: { index: 4, cfi: "epubcfi(/6/10!/4/2/8:0)", displayed: { page: 1, total: 2 } },
    atStart: false,
    atEnd: false,
  };
  const spineSections = Array.from({ length: 10 }, (_, index) => ({ index, linear: true }));
  const rendition = {
    display: vi.fn(() =>
      Promise.resolve().then(() => {
        emit("relocated", location);
      }),
    ),
    next: vi.fn(() => Promise.resolve()),
    prev: vi.fn(() => Promise.resolve()),
    getContents: vi.fn(() => [{}]),
    location,
    on,
    off,
    themes: {
      fontSize: vi.fn(),
      register: vi.fn(),
      select: vi.fn(),
    },
  };
  const book = {
    archive: {
      urlCache: {},
    },
    destroy: vi.fn(),
    loaded: { spine: Promise.resolve(Array.from({ length: 10 }, () => ({ linear: "yes" }))) },
    locations: {
      generate: vi.fn(() => Promise.resolve([location.start.cfi, location.end.cfi])),
      percentageFromCfi: vi.fn<(cfi: string) => number | null>(() => 0.42),
    },
    open: vi.fn(() => Promise.resolve()),
    opened: Promise.resolve(),
    renderTo: vi.fn(() => rendition),
    resources: { replacementUrls: [] },
    spine: {
      each: vi.fn((callback: (section: { index: number; linear: boolean }) => void) => spineSections.forEach(callback)),
      hooks: { serialize: { register: vi.fn() } },
    },
  };
  return { book, emit, listeners, location, rendition, spineSections };
};

const readerProps = (overrides: Record<string, unknown> = {}) => ({
  file_type: "epub",
  latest_media_location: {
    cfi: "epubcfi(/6/10!/4/2/1:0)",
    location: 42,
    timestamp: "2026-07-20T12:00:00.000Z",
  },
  product_file_id: "epub-file",
  purchase_id: "purchase",
  read_id: `read-${crypto.randomUUID()}`,
  title: "Reader test",
  url: "https://files.example.test/book.epub?signature=1",
  url_redirect_id: "redirect",
  ...overrides,
});

describe("PDF progress compatibility", () => {
  it("accepts page cookies and rejects EPUB or media progress", () => {
    expect(canResumePdfFromLocation({ location: 8 })).toBe(true);
    expect(canResumePdfFromLocation({ location: 8, unit: "page_number" })).toBe(true);
    expect(canResumePdfFromLocation({ location: 4, cfi: "epubcfi(/6/8!/4/2/1:0)" })).toBe(false);
    expect(canResumePdfFromLocation({ location: 42, unit: "percentage" })).toBe(false);
    expect(canResumePdfFromLocation({ location: 120, unit: "seconds" })).toBe(false);
  });
});

describe("EPUB reader lifecycle", () => {
  let harness: ReturnType<typeof buildEpubHarness>;

  beforeEach(() => {
    vi.stubGlobal(
      "fetch",
      vi.fn(() => Promise.resolve(new Response(new Uint8Array([1, 2, 3]), { headers: { "content-length": "3" } }))),
    );
    harness = buildEpubHarness();
    mocks.createEpub.mockReturnValue(harness.book);
    mocks.usePage.mockReturnValue({ props: readerProps() });
    mocks.trackMediaLocationChanged.mockResolvedValue(undefined);
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
    vi.unstubAllGlobals();
  });

  it("resumes from the server CFI and persists visible reading progress", async () => {
    render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalledWith("epubcfi(/6/10!/4/2/1:0)"));
    expect(harness.book.open).toHaveBeenCalledWith(expect.any(ArrayBuffer));
    expect(harness.book.spine.hooks.serialize.register).toHaveBeenCalledWith(expect.any(Function));
    expect(harness.book.locations.generate).not.toHaveBeenCalled();
    expect(mocks.trackMediaLocationChanged).not.toHaveBeenCalled();

    harness.location.start.cfi = "epubcfi(/6/10!/4/2/8:0)";
    act(() => harness.emit("relocated", harness.location));
    await waitFor(() =>
      expect(mocks.trackMediaLocationChanged).toHaveBeenCalledWith(
        expect.objectContaining({ epubCfi: harness.location.start.cfi, location: 40 }),
      ),
    );
  });

  it("treats an out-of-range legacy section as stale after replacement", async () => {
    mocks.usePage.mockReturnValue({
      props: readerProps({
        latest_media_location: {
          cfi: null,
          location: 100,
          timestamp: "2026-07-20T12:00:00.000Z",
          unit: "page_number",
        },
      }),
    });

    render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalledWith(undefined));
  });

  it("shows the first spread without generating a whole-book location map", async () => {
    render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());
    expect(screen.queryByText("One moment while we prepare your reading experience")).toBeNull();
    expect(harness.book.locations.generate).not.toHaveBeenCalled();
  });

  it("aborts an EPUB download when streamed bytes exceed the limit", async () => {
    const cancel = vi.fn();
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2]));
        controller.enqueue(new Uint8Array([3, 4]));
      },
      cancel,
    });
    vi.mocked(fetch).mockResolvedValueOnce(new Response(stream, { headers: { "content-length": "3" } }));

    await expect(
      downloadEpubArchive("https://files.example.test/large.epub", new AbortController().signal, 3),
    ).rejects.toThrow("EPUB archive exceeds the reader memory limit");
    expect(cancel).toHaveBeenCalledOnce();
  });

  it("waits for packaged resource replacement before rendering", async () => {
    let resolveOpened: () => void = () => undefined;
    harness.book.opened = new Promise<void>((resolve) => {
      resolveOpened = resolve;
    });
    render(<Read />);

    await waitFor(() => expect(harness.book.open).toHaveBeenCalled());
    expect(harness.book.renderTo).not.toHaveBeenCalled();

    resolveOpened();
    await waitFor(() => expect(harness.book.renderTo).toHaveBeenCalled());
  });

  it("waits for relocation before settling initial fallback progress", async () => {
    mocks.usePage.mockReturnValue({ props: readerProps({ latest_media_location: null }) });
    harness.rendition.display.mockImplementation(() => Promise.resolve());
    Object.assign(harness.rendition, { location: undefined });
    render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());
    await waitFor(() => expect(screen.queryByText("One moment while we prepare your reading experience")).toBeNull());
    expect(mocks.trackMediaLocationChanged).not.toHaveBeenCalled();
    expect(screen.queryByText("Sorry, this EPUB could not be opened.")).toBeNull();

    act(() => harness.emit("relocated", harness.location));
    await waitFor(() => expect(mocks.trackMediaLocationChanged).toHaveBeenCalled());
  });

  it("does not overwrite stored progress before the reader moves", async () => {
    const { unmount } = render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());
    unmount();

    expect(mocks.trackMediaLocationChanged).not.toHaveBeenCalled();
  });

  it("replaces a rejected stored CFI with the fallback start location", async () => {
    harness.rendition.display.mockRejectedValueOnce(new Error("Stored CFI is invalid"));
    harness.location.start.index = 0;
    harness.location.start.cfi = "epubcfi(/6/2!/4/2/1:0)";
    render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalledTimes(2));
    await waitFor(() =>
      expect(mocks.trackMediaLocationChanged).toHaveBeenCalledWith(
        expect.objectContaining({ epubCfi: harness.location.start.cfi, location: 0 }),
      ),
    );
  });

  it("persists completion for a one-spread EPUB", async () => {
    mocks.usePage.mockReturnValue({ props: readerProps({ latest_media_location: null }) });
    harness.book.loaded.spine = Promise.resolve([{ linear: "yes" }]);
    harness.spineSections.splice(0, harness.spineSections.length, { index: 0, linear: true });
    harness.location.start.index = 0;
    harness.location.start.displayed = { page: 1, total: 1 };
    harness.location.atEnd = true;
    render(<Read />);

    await waitFor(() =>
      expect(mocks.trackMediaLocationChanged).toHaveBeenCalledWith(
        expect.objectContaining({ epubCfi: harness.location.start.cfi, location: 100 }),
      ),
    );
  });

  it("persists visible-page progress for an image-only EPUB", async () => {
    harness.book.loaded.spine = Promise.resolve([{ linear: "yes" }]);
    harness.spineSections.splice(0, harness.spineSections.length, { index: 0, linear: true });
    harness.location.start.displayed = { page: 1, total: 4 };
    harness.location.start.index = 0;
    render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());
    harness.location.start.cfi = "epubcfi(/6/2!/4/2/4:0)";
    harness.location.start.displayed = { page: 2, total: 4 };
    act(() => harness.emit("relocated", harness.location));

    await waitFor(() =>
      expect(mocks.trackMediaLocationChanged).toHaveBeenCalledWith(expect.objectContaining({ location: 25 })),
    );
  });

  it("persists completion for a one-spread image EPUB", async () => {
    harness.book.loaded.spine = Promise.resolve([{ linear: "yes" }]);
    harness.spineSections.splice(0, harness.spineSections.length, { index: 0, linear: true });
    harness.location.start.index = 0;
    harness.location.start.displayed = { page: 1, total: 1 };
    harness.location.atEnd = true;
    render(<Read />);

    await waitFor(() =>
      expect(mocks.trackMediaLocationChanged).toHaveBeenCalledWith(
        expect.objectContaining({ epubCfi: harness.location.start.cfi, location: 100 }),
      ),
    );
  });

  it("ignores non-linear spine entries in image-only progress", async () => {
    harness.book.loaded.spine = Promise.resolve(Array.from({ length: 4 }, () => ({ linear: "yes" })));
    harness.spineSections.splice(
      0,
      harness.spineSections.length,
      { index: 0, linear: false },
      { index: 1, linear: true },
      { index: 2, linear: false },
      { index: 3, linear: true },
    );
    harness.location.start.index = 1;
    harness.location.start.displayed = { page: 1, total: 1 };
    render(<Read />);

    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());
    expect(screen.getByText("1 of 2")).toBeDefined();
    fireEvent.change(screen.getByLabelText("Section"), { target: { value: "2" } });
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalledWith(3));

    harness.location.start.cfi = "epubcfi(/6/8!/4/2/1:0)";
    harness.location.start.index = 3;
    act(() => harness.emit("relocated", harness.location));

    await waitFor(() =>
      expect(mocks.trackMediaLocationChanged).toHaveBeenCalledWith(expect.objectContaining({ location: 50 })),
    );
  });

  it("registers iframe-safe themes and updates the active rendition", async () => {
    render(<Read />);
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());

    expect(harness.rendition.themes.register).toHaveBeenCalledWith(
      "dark",
      expect.objectContaining({
        "body.dark": { "background-color": "#121212 !important", color: "#e6e6e6 !important" },
      }),
    );
    fireEvent.click(screen.getByLabelText("Appearance"));
    fireEvent.click(await screen.findByRole("radio", { name: "Dark" }));

    expect(harness.rendition.themes.select).toHaveBeenLastCalledWith("dark");
  });

  it("does not turn pages when a reader control handles an arrow key", async () => {
    render(<Read />);
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());

    fireEvent.keyDown(screen.getByLabelText("Section"), { key: "ArrowRight" });
    expect(harness.rendition.next).not.toHaveBeenCalled();

    fireEvent.keyDown(window, { key: "ArrowRight" });
    expect(harness.rendition.next).toHaveBeenCalledOnce();
  });

  it("shows a recovery error when epub.js emits displayerror and leaves display pending", async () => {
    harness.rendition.display.mockImplementation(() => new Promise(() => undefined));
    mocks.usePage.mockReturnValue({ props: readerProps({ latest_media_location: null }) });
    render(<Read />);
    await waitFor(() => expect(harness.listeners.get("displayerror")?.size).toBe(1));

    act(() => harness.emit("displayerror", new Error("Spine document is missing")));

    expect((await screen.findByRole("alert")).textContent).toContain("We couldn't open this EPUB");
    expect(harness.book.destroy).toHaveBeenCalledOnce();
  });

  it("keeps displayerror recovery active after the first section opens", async () => {
    render(<Read />);
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());

    act(() => harness.emit("displayerror", new Error("Later spine document is missing")));

    expect((await screen.findByRole("alert")).textContent).toContain("We couldn't open this EPUB");
    expect(harness.book.destroy).toHaveBeenCalledOnce();
  });

  it("shows recovery when patched epub.js propagates a next-page load failure", async () => {
    harness.rendition.next.mockRejectedValue(new Error("Unable to load next section"));
    render(<Read />);
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());

    fireEvent.click(screen.getByRole("button", { name: "Next" }));

    expect((await screen.findByRole("alert")).textContent).toContain("We couldn't open this EPUB");
    expect(harness.book.destroy).toHaveBeenCalledOnce();
  });

  it("destroys the epub.js book when the reader unmounts", async () => {
    const { unmount } = render(<Read />);
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());

    unmount();

    expect(harness.book.destroy).toHaveBeenCalledOnce();
  });

  it("destroys resources created when opening finishes after unmount", async () => {
    let resolveOpen: () => void = () => undefined;
    harness.book.open = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveOpen = resolve;
        }),
    );
    const { unmount } = render(<Read />);
    await waitFor(() => expect(harness.book.open).toHaveBeenCalled());

    unmount();
    expect(harness.book.destroy).toHaveBeenCalledOnce();

    resolveOpen();
    await waitFor(() => expect(harness.book.destroy).toHaveBeenCalledTimes(2));
    expect(harness.book.renderTo).not.toHaveBeenCalled();
  });

  it("destroys the epub.js book before a full-page navigation", async () => {
    render(<Read />);
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());

    window.dispatchEvent(new Event("pagehide"));

    expect(harness.book.destroy).toHaveBeenCalledOnce();
  });

  it("keeps the reader alive when pagehide enters the back-forward cache", async () => {
    const { unmount } = render(<Read />);
    await waitFor(() => expect(harness.rendition.display).toHaveBeenCalled());
    const pageHide = new Event("pagehide");
    Object.defineProperty(pageHide, "persisted", { value: true });

    window.dispatchEvent(pageHide);

    expect(harness.book.destroy).not.toHaveBeenCalled();
    unmount();
    expect(harness.book.destroy).toHaveBeenCalledOnce();
  });
});
