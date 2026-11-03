// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ProductBuild } from "$app/data/product_builds";
import { cast } from "$app/utils/cast";

import { VersionHistoryButton } from "$app/components/ProductEdit/ContentTab/VersionHistoryButton";

const getProductBuilds = vi.fn<() => Promise<ProductBuild[]>>();
const promoteProductBuild = vi.fn<() => Promise<void>>();
const createProductBuild = vi.fn<(permalink: string, url: string) => Promise<ProductBuild>>();
vi.mock("$app/data/product_builds", () => ({
  getProductBuilds: () => getProductBuilds(),
  promoteProductBuild: () => promoteProductBuild(),
  createProductBuild: (permalink: string, url: string) => createProductBuild(permalink, url),
}));
const showAlert = vi.fn<(message: string, type: string) => void>();
vi.mock("$app/components/server-components/Alert", () => ({
  showAlert: (message: string, type: string) => showAlert(message, type),
}));
// Completes the upload at once, as if S3 had the whole zip.
const scheduleUpload = vi.fn((options: { onComplete: () => void }) => {
  options.onComplete();
  return 1;
});
vi.mock("$app/components/EvaporateUploader", () => ({
  useEvaporateUploader: () => ({ scheduleUpload, cancelUpload: vi.fn() }),
}));
vi.mock("$app/components/S3UploadConfig", () => ({
  useS3UploadConfig: () => ({
    generateS3KeyForUpload: (guid: string, name: string) => ({
      s3key: `attachments/seller/${guid}/original/${name}`,
      fileUrl: `https://s3.example.com/bucket/attachments/seller/${guid}/original/${name}`,
    }),
  }),
}));
const save = vi.fn<() => Promise<boolean>>();
const setWebAppUploading = vi.fn<(uploading: boolean) => void>();
let uploading = false;
let liveRowShown = true;
vi.mock("$app/components/ProductEdit/state", () => ({
  useProductEditContext: () => ({ uniquePermalink: "demo", save, product: {}, setWebAppUploading }),
  filesAreUploading: () => uploading,
  hasLiveBuildFile: () => liveRowShown,
}));

const build = (number: number, status: ProductBuild["status"]): ProductBuild => ({
  id: `build${number}`,
  number,
  status,
  byte_size: 2048,
  created_at: "2026-10-29T12:00:00Z",
  promoted_at: null,
});

// Opens the history, then "Make live" on v1 from its row menu, which asks to confirm.
const openConfirm = async () => {
  render(<VersionHistoryButton />);
  fireEvent.click(screen.getByRole("button", { name: "History" }));
  fireEvent.click(await screen.findByRole("button", { name: "Actions for version 1" }));
  fireEvent.click(await screen.findByRole("menuitem", { name: "Make live" }));
  return screen.findByRole("button", { name: "Make version 1 live" });
};

describe("VersionHistoryButton", () => {
  const originalLocation = window.location;
  beforeEach(() => {
    vi.clearAllMocks();
    // js-routes injects Routes as a global in the app; only the CLI link's path is read here.
    vi.stubGlobal("Routes", { api_path: () => "/api" });
    uploading = false;
    liveRowShown = true;
    getProductBuilds.mockResolvedValue([build(2, "live"), build(1, "superseded")]);
    save.mockResolvedValue(true);
    Object.defineProperty(window, "location", { configurable: true, value: { reload: vi.fn() } });
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    Object.defineProperty(window, "location", { configurable: true, value: originalLocation });
  });

  // Rows of the version list, top to bottom, by their first line.
  const versionRowElements = () => [
    ...screen.getByRole("region", { name: "Versions" }).querySelectorAll("[role=listitem]"),
  ];
  const versionRows = () =>
    versionRowElements().map((row) => row.querySelector("h4")?.textContent?.replace("Live", "").trim());

  it("lists the versions newest first and marks the live one", async () => {
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const live = await screen.findByRole("listitem", { name: "Version 2" });
    expect(live.textContent).toContain("Live");
    expect(live.textContent).toContain("Buyers get this version");
    expect(versionRows()).toEqual(["Version 2", "Version 1"]);
    expect(screen.queryByRole("button", { name: "Actions for version 2" })).toBeNull();
    expect(screen.getByRole("button", { name: "Actions for version 1" })).toBeDefined();
  });

  it("puts a version added after the live one first, with Make live in view", async () => {
    getProductBuilds.mockResolvedValue([build(3, "uploaded"), build(2, "live"), build(1, "uploaded")]);
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const ready = await screen.findByRole("listitem", { name: "Version 3" });
    expect(ready.textContent).toContain("Not live yet");
    expect(screen.getByRole("listitem", { name: "Version 1" }).textContent).not.toContain("Not live yet");
    fireEvent.click(screen.getByRole("button", { name: "Make live" }));
    expect(await screen.findByRole("dialog", { name: "Make version 3 live?" })).toBeDefined();
  });

  it("offers to add the live version back when its row is not in the content", async () => {
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));
    await screen.findByRole("listitem", { name: "Version 2" });
    expect(screen.queryByRole("button", { name: "Add to content" })).toBeNull();
    cleanup();

    liveRowShown = false;
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));
    fireEvent.click(await screen.findByRole("button", { name: "Add to content" }));
    expect(await screen.findByRole("dialog", { name: "Add version 2 back to the content?" })).toBeDefined();
  });

  it("uploads a zip as a new version and shows it ready to go live", async () => {
    // The new version shows without loading the list again, so a failed reload cannot hide it.
    getProductBuilds.mockResolvedValueOnce([build(1, "live")]).mockRejectedValue(new Error("offline"));
    createProductBuild.mockResolvedValue(build(2, "uploaded"));
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));
    await screen.findByRole("listitem", { name: "Version 1" });

    fireEvent.change(screen.getByLabelText("Web app zip"), {
      target: { files: [new File(["PK"], "my game.zip", { type: "application/zip" })] },
    });

    expect((await screen.findByRole("listitem", { name: "Version 2" })).textContent).toContain("Not live yet");
    expect(screen.getByText("Version 2 is ready to go live.")).toBeDefined();
    expect(createProductBuild).toHaveBeenCalledWith("demo", expect.stringMatching(/\/original\/my game\.zip$/u));
    expect(showAlert).not.toHaveBeenCalled();
  });

  it("shows the upload as the list's first row, which becomes the new version", async () => {
    let complete = () => {};
    scheduleUpload.mockImplementationOnce((options: { onComplete: () => void }) => {
      complete = options.onComplete;
      return 1;
    });
    createProductBuild.mockResolvedValue(build(3, "uploaded"));
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));
    await screen.findByRole("listitem", { name: "Version 2" });

    fireEvent.change(screen.getByLabelText("Web app zip"), {
      target: { files: [new File(["PK"], "game.zip", { type: "application/zip" })] },
    });
    expect(versionRows()).toEqual(["Uploading game.zip", "Version 2", "Version 1"]);
    expect(screen.getByText("Uploading game.zip: 0%").getAttribute("role")).toBe("status");
    expect(screen.getByRole("button", { name: "Upload a zip" })).toHaveProperty("disabled", true);
    expect(setWebAppUploading).toHaveBeenLastCalledWith(true);

    act(() => complete());
    await screen.findByRole("listitem", { name: "Version 3" });
    expect(versionRows()).toEqual(["Version 3", "Version 2", "Version 1"]);
    expect(setWebAppUploading).toHaveBeenLastCalledWith(false);
  });

  it("does not make a version live while a zip uploads", async () => {
    scheduleUpload.mockImplementationOnce(() => 1);
    getProductBuilds.mockResolvedValue([build(2, "uploaded"), build(1, "live")]);
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));
    await screen.findByRole("listitem", { name: "Version 2" });

    fireEvent.change(screen.getByLabelText("Web app zip"), {
      target: { files: [new File(["PK"], "game.zip", { type: "application/zip" })] },
    });
    fireEvent.click(screen.getByRole("button", { name: "Make live" }));

    expect(await screen.findByRole("button", { name: "Make version 2 live" })).toHaveProperty("disabled", true);
  });

  it("refuses a file that is not a zip", async () => {
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));
    await screen.findByRole("listitem", { name: "Version 2" });

    fireEvent.change(screen.getByLabelText("Web app zip"), { target: { files: [new File(["x"], "game.html")] } });

    expect(scheduleUpload).not.toHaveBeenCalled();
    expect(showAlert).toHaveBeenCalledWith("Choose a .zip file of your web app.", "error");
  });

  it("puts the upload above the versions and the command line below them", async () => {
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const versions = await screen.findByRole("region", { name: "Versions" });
    const add = screen.getByRole("region", { name: "Add a new version" });
    const cli = screen.getByRole("region", { name: "Deploy from the command line" });
    expect(add.compareDocumentPosition(versions) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(versions.compareDocumentPosition(cli) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
    expect(cli.textContent).toContain("gumroad builds deploy ./my-web-app --product demo");
  });

  it("asks for a first web app when the product has no versions", async () => {
    getProductBuilds.mockResolvedValue([]);
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const add = await screen.findByRole("region", { name: "Add a web app" });
    expect(screen.getByRole("dialog", { name: "Add a web app" })).toBeDefined();
    expect(add.textContent).toContain("Buyers get it once you make it live.");
    expect(screen.queryByRole("region", { name: "Versions" })).toBeNull();
  });

  it("shows the last ten earlier builds until asked for all", async () => {
    getProductBuilds.mockResolvedValue([
      build(13, "live"),
      ...Array.from({ length: 12 }, (_, i) => build(12 - i, "superseded")),
    ]);
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    await screen.findByRole("listitem", { name: "Version 13" });
    expect(versionRowElements()).toHaveLength(11);
    fireEvent.click(screen.getByRole("button", { name: "Show all 13 versions" }));
    expect(versionRowElements()).toHaveLength(13);
  });

  it("saves, makes the build live, then reloads", async () => {
    fireEvent.click(await openConfirm());

    await waitFor(() => expect(cast<{ reload: () => void }>(window.location).reload).toHaveBeenCalled());
    expect(save).toHaveBeenCalledBefore(promoteProductBuild);
    expect(screen.getByRole("button", { name: "Saving..." })).toHaveProperty("disabled", true);
  });

  it("does not make a build live when the save fails", async () => {
    save.mockResolvedValue(false);

    fireEvent.click(await openConfirm());

    await waitFor(() => expect(save).toHaveBeenCalled());
    expect(promoteProductBuild).not.toHaveBeenCalled();
  });

  it("waits for uploads to finish", async () => {
    uploading = true;

    const makeLive = await openConfirm();

    expect(makeLive).toHaveProperty("disabled", true);
    expect(screen.getByText("Wait for your files to finish uploading.")).toBeDefined();
  });

  it("stays open while a build is being made live", async () => {
    promoteProductBuild.mockReturnValue(new Promise(() => undefined));

    fireEvent.click(await openConfirm());
    await waitFor(() => expect(promoteProductBuild).toHaveBeenCalled());
    fireEvent.keyDown(screen.getByRole("dialog", { name: "Make version 1 live?" }), { key: "Escape" });

    expect(screen.getByRole("dialog", { name: "Make version 1 live?" })).toBeDefined();
    expect(screen.queryByRole("button", { name: "Close" })).toBeNull();
  });
});
