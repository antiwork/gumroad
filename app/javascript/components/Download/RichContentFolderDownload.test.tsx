// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, expect, it, vi } from "vitest";

import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { FileItem } from "$app/components/Download/FileList";
import { FilesAndFoldersDownloadInfoProvider, RichContentView } from "$app/components/Download/RichContent";
import {
  ContentFilesProvider,
  IsMobileAppViewProvider,
  MediaUrlsProvider,
  PurchaseInfoProvider,
} from "$app/components/DownloadPage/WithContent";
import { UserAgentProvider } from "$app/components/UserAgent";

vi.mock("$app/data/user_action_event", () => ({ trackUserActionEvent: vi.fn() }));
vi.mock("$app/data/consumption_analytics", () => ({ createConsumptionEvent: vi.fn() }));

// A granted file has a download_url but is left out of the shared folder archive.
const pdf = (id: string, { downloadable = true, archivable = true } = {}): FileItem => ({
  type: "file",
  id,
  file_name: `File ${id}`,
  description: null,
  extension: "PDF",
  file_size: 100,
  pagelength: 1,
  duration: null,
  content_length: null,
  download_url: downloadable ? `/d/token/product_files?product_file_ids[]=${id}` : null,
  archivable,
  latest_media_location: null,
  stream_url: null,
  external_link_url: null,
  kindle_data: null,
  read_url: `/read/${id}`,
  pdf_stamp_enabled: false,
  processing: false,
  thumbnail_url: null,
});
const granted = (id: string) => pdf(id, { archivable: false });
const ungranted = (id: string) => pdf(id, { downloadable: false, archivable: false });

const getFolderArchive = vi.fn<(folderId: string) => Promise<{ url: string | null }>>();

beforeEach(() => {
  vi.stubGlobal("SSR", false);
  getFolderArchive.mockResolvedValue({ url: null });
});

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

const renderFolder = (files: FileItem[]) =>
  render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "gumroad.com",
        rootDomain: "gumroad.com",
        shortDomain: "gum.co",
        discoverDomain: "gumroad.com",
        thirdPartyAnalyticsDomain: "example.com",
        apiDomain: "api.gumroad.com",
      }}
    >
      <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
        <PurchaseInfoProvider value={{ purchaseId: "purchase", redirectId: "redirect", token: "token" }}>
          <MediaUrlsProvider value={[{}, vi.fn()]}>
            <IsMobileAppViewProvider value={false}>
              <ContentFilesProvider value={files}>
                <FilesAndFoldersDownloadInfoProvider
                  value={{
                    downloadableFiles: files.flatMap((file) =>
                      file.download_url ? [{ id: file.id, url: file.download_url, size: file.file_size ?? 0 }] : [],
                    ),
                    isMobileAppWebView: false,
                    pdfStampingEnabled: false,
                    getFolderArchive,
                    getDownloadUrlsForFiles: vi.fn(),
                    hasStreamable: () => false,
                  }}
                >
                  <RichContentView
                    richContent={{
                      type: "doc",
                      content: [
                        {
                          type: "fileEmbedGroup",
                          attrs: { uid: "folder", name: "Folder", expandedByDefault: true },
                          content: files.map((file) => ({ type: "fileEmbed", attrs: { id: file.id } })),
                        },
                      ],
                    }}
                    saleInfo={null}
                    license={null}
                  />
                </FilesAndFoldersDownloadInfoProvider>
              </ContentFilesProvider>
            </IsMobileAppViewProvider>
          </MediaUrlsProvider>
        </PurchaseInfoProvider>
      </UserAgentProvider>
    </DomainSettingsProvider>,
  );

const rowOf = (file: FileItem) => {
  const row = screen.getByText(file.file_name).closest("[role=treeitem]");
  if (!(row instanceof HTMLElement)) throw new Error(`No row for ${file.file_name}`);
  return row;
};

const openDownloadAll = async () => {
  fireEvent.click(await screen.findByRole("button", { name: "Download all" }));
  return screen.findByRole("button", { name: "Save to Dropbox" });
};

it.each([
  ["one normal file and a granted file", [pdf("a"), granted("g")]],
  ["two normal files and a granted file", [pdf("a"), pdf("b"), granted("g")]],
  ["only granted files", [granted("g1"), granted("g2")]],
])("offers no folder ZIP for %s, keeping Dropbox and each file's own Download", async (_, files) => {
  renderFolder(files);
  await openDownloadAll();

  expect(screen.queryByRole("button", { name: "Download as ZIP" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Zipping files..." })).toBeNull();
  expect(getFolderArchive).not.toHaveBeenCalled();
  for (const file of files) {
    expect(within(rowOf(file)).getByRole("link", { name: "Download" }).getAttribute("href")).toBe(file.download_url);
  }
});

it("offers the folder ZIP for two normal files", async () => {
  renderFolder([pdf("a"), pdf("b")]);
  await openDownloadAll();

  fireEvent.click(screen.getByRole("button", { name: "Download as ZIP" }));
  expect(getFolderArchive).toHaveBeenCalledWith("folder");
});

it("offers the folder ZIP to a buyer without the grant, whose disabled file is not downloadable", async () => {
  const disabled = ungranted("g");
  renderFolder([pdf("a"), pdf("b"), disabled]);
  await openDownloadAll();

  expect(screen.getByRole("button", { name: "Download as ZIP" })).toBeDefined();
  expect(within(rowOf(disabled)).queryByRole("link", { name: "Download" })).toBeNull();
});

it("links straight to a lone granted file", async () => {
  renderFolder([granted("g"), ungranted("other")]);
  await openDownloadAll();

  expect(screen.getByRole("link", { name: "Download file" }).getAttribute("href")).toBe(granted("g").download_url);
  expect(screen.queryByRole("button", { name: "Download as ZIP" })).toBeNull();
});
