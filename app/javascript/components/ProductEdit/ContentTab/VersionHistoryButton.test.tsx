// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ProductBuild } from "$app/data/product_builds";
import { cast } from "$app/utils/cast";

import { VersionHistoryButton } from "$app/components/ProductEdit/ContentTab/VersionHistoryButton";

const getProductBuilds = vi.fn<() => Promise<ProductBuild[]>>();
const promoteProductBuild = vi.fn<() => Promise<void>>();
vi.mock("$app/data/product_builds", () => ({
  getProductBuilds: () => getProductBuilds(),
  promoteProductBuild: () => promoteProductBuild(),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
const save = vi.fn<() => Promise<boolean>>();
let uploading = false;
vi.mock("$app/components/ProductEdit/state", () => ({
  useProductEditContext: () => ({ uniquePermalink: "demo", save, product: {} }),
  filesAreUploading: () => uploading,
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
    getProductBuilds.mockResolvedValue([build(2, "live"), build(1, "superseded")]);
    save.mockResolvedValue(true);
    Object.defineProperty(window, "location", { configurable: true, value: { reload: vi.fn() } });
  });
  afterEach(() => {
    cleanup();
    vi.unstubAllGlobals();
    Object.defineProperty(window, "location", { configurable: true, value: originalLocation });
  });

  it("shows the live build apart from the earlier ones", async () => {
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const live = await screen.findByRole("region", { name: "Live version" });
    expect(live.textContent).toContain("Version 2");
    expect(live.textContent).toContain("Buyers get this version");
    expect(screen.getByRole("region", { name: "Earlier versions" }).textContent).toContain("Version 1");
    expect(screen.queryByRole("button", { name: "Actions for version 2" })).toBeNull();
  });

  it("puts a version deployed after the live one first, with Make live in view", async () => {
    getProductBuilds.mockResolvedValue([build(3, "uploaded"), build(2, "live"), build(1, "uploaded")]);
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const ready = await screen.findByRole("region", { name: "Ready to go live" });
    expect(ready.textContent).toContain("Version 3");
    expect(ready.textContent).not.toContain("Version 1");
    expect(screen.getByRole("region", { name: "Earlier versions" }).textContent).toContain("Version 1");
    fireEvent.click(screen.getByRole("button", { name: "Make live" }));
    expect(await screen.findByRole("dialog", { name: "Make version 3 live?" })).toBeDefined();
  });

  it("shows a deploy command for this product", async () => {
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const add = await screen.findByRole("region", { name: "Add a new version" });
    expect(add.textContent).toContain("gumroad builds deploy ./my-game --product demo");
  });

  it("shows the last ten earlier builds until asked for all", async () => {
    getProductBuilds.mockResolvedValue([
      build(13, "live"),
      ...Array.from({ length: 12 }, (_, i) => build(12 - i, "superseded")),
    ]);
    render(<VersionHistoryButton />);
    fireEvent.click(screen.getByRole("button", { name: "History" }));

    const earlier = await screen.findByRole("region", { name: "Earlier versions" });
    expect(earlier.querySelectorAll("[role=listitem]")).toHaveLength(10);
    fireEvent.click(screen.getByRole("button", { name: "Show all 12 earlier versions" }));
    expect(earlier.querySelectorAll("[role=listitem]")).toHaveLength(12);
  });

  it("saves, makes the build live, then reloads", async () => {
    fireEvent.click(await openConfirm());

    await waitFor(() => expect(cast<{ reload: () => void }>(window.location).reload).toHaveBeenCalled());
    expect(save).toHaveBeenCalledBefore(promoteProductBuild);
    expect(screen.getByRole("button", { name: "Making live..." })).toHaveProperty("disabled", true);
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
    expect(screen.getByText("Wait for your files to finish uploading to make another version live.")).toBeDefined();
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
