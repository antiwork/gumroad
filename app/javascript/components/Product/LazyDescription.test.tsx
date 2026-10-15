// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";

import type { PublicFile } from "$app/components/Product";

const STORED_HTML = "<p>Stored description</p>";
const PUBLIC_FILES: PublicFile[] = [{ id: "file", name: "Track", extension: "MP3", file_size: 1024, url: null }];

const EditorDescription = ({ html, publicFiles }: { html: string | null; publicFiles: PublicFile[] }) => (
  <div data-testid="editor">
    {html} ({publicFiles.length} public file)
  </div>
);

// Each test decides when, and whether, the editor chunk arrives. Fresh modules per test, so
// React.lazy does not reuse an earlier test's import.
const renderLazyDescription = async (loadEditor: () => Promise<unknown>) => {
  const attempts = vi.fn();
  vi.doMock("$app/components/Product/Description", () => {
    attempts();
    return loadEditor();
  });
  const { LazyDescription } = await import("$app/components/Product/LazyDescription");
  render(<LazyDescription html={STORED_HTML} publicFiles={PUBLIC_FILES} />);
  return { attempts };
};

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.doUnmock("$app/components/Product/Description");
  vi.resetModules();
});

describe("LazyDescription", () => {
  it("shows the stored description while the editor downloads", async () => {
    await renderLazyDescription(() => new Promise(() => {}));

    expect(screen.getByText("Stored description").closest(".rich-text[dir='auto']")).toBeTruthy();
    expect(screen.queryByTestId("editor")).toBeNull();
  });

  it("hands the description and public files to the editor once it arrives", async () => {
    await renderLazyDescription(() => Promise.resolve({ Description: EditorDescription }));

    expect((await screen.findByTestId("editor")).textContent).toBe(`${STORED_HTML} (1 public file)`);
    expect(screen.queryByText("Stored description")).toBeNull();
  });

  it("keeps the stored description when the editor cannot be downloaded", async () => {
    // React logs the error the boundary catches; the fallback handling it is the point.
    vi.spyOn(console, "error").mockImplementation(() => {});
    const { attempts } = await renderLazyDescription(() =>
      Promise.reject(new Error("Failed to fetch dynamically imported module")),
    );

    await waitFor(() => expect(attempts).toHaveBeenCalledTimes(2), { timeout: 2000 });
    await waitFor(() => expect(screen.getByText("Stored description")).toBeTruthy());
    expect(screen.queryByTestId("editor")).toBeNull();
  });
});

describe("Description", () => {
  const renderDescription = async () => {
    const initialValues: unknown[] = [];
    vi.doMock("$app/components/RichTextEditor", () => ({
      useRichTextEditor: ({ initialValue }: { initialValue: unknown }) => {
        initialValues.push(initialValue);
        return null;
      },
    }));
    vi.doMock("@tiptap/react", () => ({ EditorContent: () => <div data-testid="editor" /> }));
    // The stubbed editor never uses its extensions; stubbing them keeps Tiptap out of the test.
    vi.doMock("$app/components/TiptapExtensions/PublicFileEmbed", () => ({
      PublicFileEmbed: {},
      PublicFilesSettingsContext: React.createContext(null),
    }));
    vi.doMock("$app/components/TiptapExtensions/ReviewCard", () => ({ ReviewCard: {} }));
    vi.doMock("$app/components/TiptapExtensions/UpsellCard", () => ({ UpsellCard: {} }));
    const { Description } = await import("$app/components/Product/Description");
    const element = <Description html={STORED_HTML} publicFiles={PUBLIC_FILES} fallback={<p>Stored fallback</p>} />;
    return { element, initialValues };
  };

  afterEach(() => {
    for (const path of [
      "$app/components/RichTextEditor",
      "@tiptap/react",
      "$app/components/TiptapExtensions/PublicFileEmbed",
      "$app/components/TiptapExtensions/ReviewCard",
      "$app/components/TiptapExtensions/UpsellCard",
    ])
      vi.doUnmock(path);
  });

  it("paints the stored description on its first render, before the editor mounts", async () => {
    const { element } = await renderDescription();

    expect(renderToStaticMarkup(element)).toBe("<p>Stored fallback</p>");
  });

  it("creates the editor empty and fills it after mount, so stored HTML parses as before", async () => {
    const { element, initialValues } = await renderDescription();
    render(element);

    expect(await screen.findByTestId("editor")).toBeTruthy();
    expect(initialValues[0]).toBeNull();
    expect(initialValues.at(-1)).toBe(STORED_HTML);
  });
});
