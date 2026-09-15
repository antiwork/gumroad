// @vitest-environment happy-dom
//
// The first-class Pages editor is a rich text surface like the profile's rich text sections, so
// it has to provide ImageUploadSettingsContext: the toolbar's Insert image item and the paste/drop
// handlers both read it and no-op without it.
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import PagesEdit from "$app/pages/Pages/Edit";
import { assertDefined } from "$app/utils/assert";

// `SSR` and Rails' js-routes `Routes` are vite/app globals vitest does not have.
vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));
vi.stubGlobal("fetch", () =>
  Promise.resolve(
    new Response(JSON.stringify({ url: "https://cdn.example/image.png" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }),
  ),
);
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { page: { create: true } } }),
}));
vi.mock("$app/utils/prepareImageForUpload", () => ({
  isLikelyImageFile: () => true,
  prepareImageForUpload: async (file: File) => file,
  heicDecodingLikely: () => false,
}));
vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: (error: Error | null, blob: { key: string }) => void) {
      callback(null, { key: "blob-key" });
    }
  },
}));

const props = vi.hoisted((): { current: Record<string, unknown> } => ({ current: {} }));
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: props.current }),
  router: { visit: () => {}, patch: () => {}, post: () => {}, on: () => () => {} },
}));

// The preview pane frames the page's public URL; it is not what these tests render, and letting it
// load pulls in an iframe fetch happy-dom reports as an unhandled rejection.
vi.mock("$app/components/PreviewSidebar", () => ({
  WithPreviewSidebar: ({ children }: { children: React.ReactNode }) => children,
  PreviewSidebar: () => null,
  PreviewChrome: ({ children }: { children: React.ReactNode }) => children,
}));

const renderEditor = () => {
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

afterEach(cleanup);

describe("PagesEdit", () => {
  it("offers image insert in the page content editor", () => {
    renderEditor();

    expect(screen.getByRole("button", { name: "Insert image" })).toBeTruthy();
  });

  it("uploads an image pasted into the page content editor", async () => {
    const { container } = renderEditor();

    const editor = assertDefined(container.querySelector('[aria-label="Page content"]'));
    fireEvent.paste(editor, {
      clipboardData: { files: [new File(["pixels"], "photo.png", { type: "image/png" })] },
    });

    await waitFor(() =>
      expect(container.querySelector("img")?.getAttribute("src")).toBe("https://cdn.example/image.png"),
    );
  });
});
