// @vitest-environment happy-dom
//
// The first-class Pages editor is a rich text surface like the profile's rich text sections, so
// it has to provide ImageUploadSettingsContext: the toolbar's Insert image item and the paste/drop
// handlers both read it and no-op without it.
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import PagesEdit from "$app/pages/Pages/Edit";
import { assertDefined } from "$app/utils/assert";

// `SSR` and Rails' js-routes `Routes` are vite/app globals vitest does not have.
vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));
// The CDN URL lookup is what the save guard has to cover, so it can be held open: the window
// between "blob uploaded" and "CDN URL resolved" is the one the local blob: preview survives.
const cdn = vi.hoisted((): { hold: boolean; release: (() => void)[] } => ({ hold: false, release: [] }));
vi.stubGlobal("fetch", () => {
  const response = () =>
    new Response(JSON.stringify({ url: "https://cdn.example/image.png" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  if (!cdn.hold) return Promise.resolve(response());

  return new Promise<Response>((resolve) => cdn.release.push(() => resolve(response())));
});
// Mirrors PagePolicy#create?, which the page editor reads as its edit permission.
const canEdit = vi.hoisted(() => ({ current: true }));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { page: { create: canEdit.current } } }),
}));
vi.mock("$app/utils/prepareImageForUpload", () => ({
  isLikelyImageFile: () => true,
  prepareImageForUpload: async (file: File) => file,
  heicDecodingLikely: () => false,
}));
// Uploads settle only when a test says so, so the in-flight window is observable.
type UploadCallback = (error: Error | null, blob: { key: string }) => void;
const uploads = vi.hoisted((): { pending: UploadCallback[] } => ({ pending: [] }));
vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: (error: Error | null, blob: { key: string }) => void) {
      uploads.pending.push(callback);
    }
  },
}));

const patch = vi.hoisted(() => vi.fn());
const props = vi.hoisted((): { current: Record<string, unknown> } => ({ current: {} }));
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: props.current }),
  router: { visit: () => {}, patch, post: () => {}, on: () => () => {} },
}));

// The preview pane frames the page's public URL; it is not what these tests render, and letting it
// load pulls in an iframe fetch happy-dom reports as an unhandled rejection.
vi.mock("$app/components/PreviewSidebar", () => ({
  WithPreviewSidebar: ({ children }: { children: React.ReactNode }) => children,
  PreviewSidebar: () => null,
  PreviewChrome: ({ children }: { children: React.ReactNode }) => children,
}));

const renderEditor = (readOnly = false) => {
  canEdit.current = !readOnly;
  props.current = {
    page: { slug: "about", title: "About", content: "<p>Hello</p>", custom_html: false },
    is_profile: false,
    is_new: false,
    username: "seller",
    profile_url: "https://seller.gumroad.com/",
    products_page_limit: 4,
  };

  return render(<PagesEdit />);
};

const pasteImage = (container: HTMLElement) =>
  fireEvent.paste(assertDefined(container.querySelector('[aria-label="Page content"]')), {
    clipboardData: { files: [new File(["pixels"], "photo.png", { type: "image/png" })] },
  });

const settleUpload = (blob = { key: "blob-key" }) => {
  const callback = assertDefined(uploads.pending.shift());
  callback(null, blob);
};

beforeEach(() => {
  uploads.pending.length = 0;
  cdn.hold = false;
  cdn.release.length = 0;
  patch.mockClear();
});

afterEach(cleanup);

describe("PagesEdit", () => {
  it("offers image insert in the page content editor", () => {
    renderEditor();

    expect(screen.getByRole("button", { name: "Insert image" })).toBeTruthy();
  });

  it("uploads an image pasted into the page content editor", async () => {
    const { container } = renderEditor();
    pasteImage(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(1));
    settleUpload();

    await waitFor(() =>
      expect(container.querySelector("img")?.getAttribute("src")).toBe("https://cdn.example/image.png"),
    );
  });

  it("offers no upload affordance to a viewer without page-edit permission", async () => {
    const { container } = renderEditor(true);

    expect(screen.queryByRole("button", { name: "Insert image" })).toBeNull();

    pasteImage(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(0));
    expect(container.querySelector("img")).toBeNull();
  });

  it("holds the save until an in-flight image has an uploaded URL", async () => {
    const { container } = renderEditor();
    pasteImage(container);
    await waitFor(() => expect(container.querySelector("img")).toBeTruthy());

    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(patch).not.toHaveBeenCalled();

    settleUpload();
    await waitFor(() =>
      expect(container.querySelector("img")?.getAttribute("src")).toBe("https://cdn.example/image.png"),
    );
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(patch).toHaveBeenCalledTimes(1);
    expect(patch.mock.calls[0]?.[1]).toMatchObject({ content: expect.stringContaining("https://cdn.example") });
  });

  it("holds the save until an uploaded image has its CDN URL, not just its blob", async () => {
    const { container } = renderEditor();
    cdn.hold = true;
    pasteImage(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(1));

    // The blob is up, but the editor still shows the local preview: saving now would persist a
    // blob: src, which the sanitizer strips.
    settleUpload();
    await waitFor(() => expect(cdn.release).toHaveLength(1));

    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(patch).not.toHaveBeenCalled();

    cdn.release.forEach((release) => release());
    await waitFor(() =>
      expect(container.querySelector("img")?.getAttribute("src")).toBe("https://cdn.example/image.png"),
    );
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(patch).toHaveBeenCalledTimes(1);
  });
});
