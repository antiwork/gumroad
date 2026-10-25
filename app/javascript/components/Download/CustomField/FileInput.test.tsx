// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

const purchaseInfo = { purchaseId: "purchase-1", token: "token-1" };
const purchaseCustomFields: { custom_field_id: string; type: string; files: unknown[] }[] = [];

vi.mock("$app/components/DownloadPage/WithContent", () => ({
  usePurchaseInfo: () => purchaseInfo,
  usePurchaseCustomFields: () => purchaseCustomFields,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/utils/request", async () => ({
  ...(await vi.importActual<typeof import("$app/utils/request")>("$app/utils/request")),
  request: vi.fn(),
}));
vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: (error: null, blob: { signed_id: string }) => void) {
      callback(null, { signed_id: "blob-1" });
    }
  },
}));
vi.stubGlobal("Routes", {
  rails_direct_uploads_path: () => "/direct_uploads",
  purchase_custom_fields_path: () => "/custom_fields",
});

import { request } from "$app/utils/request";

import { FileInput } from "$app/components/Download/CustomField/FileInput";
import { showAlert } from "$app/components/server-components/Alert";

afterEach(cleanup);

describe("FileInput upload control", () => {
  it.each([401, 404, 422])("does not show a successful upload after HTTP %s", async (status) => {
    vi.mocked(showAlert).mockClear();
    vi.mocked(request).mockResolvedValueOnce(new Response(null, { status }));
    render(<FileInput customFieldId="cf-1" />);
    fireEvent.change(screen.getByLabelText("Upload files"), { target: { files: [new File(["hello"], "notes.txt")] } });
    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Error uploading files. Please try again.", "error"));
    expect(showAlert).not.toHaveBeenCalledWith("Files uploaded successfully!", "success");
    expect(screen.queryByText("notes")).toBeNull();
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Upload files" }).disabled).toBe(false);
  });

  it("adds files only after the server accepts them", async () => {
    vi.mocked(showAlert).mockClear();
    vi.mocked(request).mockResolvedValueOnce(new Response(null, { status: 204 }));
    render(<FileInput customFieldId="cf-1" />);
    fireEvent.change(screen.getByLabelText("Upload files"), {
      target: { files: [new File(["hello"], "accepted.txt")] },
    });
    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Files uploaded successfully!", "success"));
    expect(screen.queryByText("accepted")).not.toBeNull();
  });

  // The picker only opens if the ref'd input receives the click, so the spy stands in for the
  // browser's file dialog: a control that stops forwarding the click fails here.
  it("opens the file picker from a single click", () => {
    const picked: HTMLInputElement[] = [];
    const click = vi.spyOn(HTMLInputElement.prototype, "click").mockImplementation(function (this: HTMLInputElement) {
      picked.push(this);
    });

    render(<FileInput customFieldId="cf-1" />);
    fireEvent.click(screen.getByRole("button", { name: "Upload files" }));

    expect(click).toHaveBeenCalledTimes(1);
    expect(picked[0]).toBe(screen.getByLabelText("Upload files"));
    click.mockRestore();
  });

  it("renders a button instead of a label wrapping the input", () => {
    render(<FileInput customFieldId="cf-1" />);

    const input = screen.getByLabelText("Upload files");
    expect(screen.getByRole("button", { name: "Upload files" }).tagName).toBe("BUTTON");
    expect(input.closest("label")).toBeNull();
  });

  // Request specs attach files by this label, so the input has to stay discoverable.
  it("keeps the hidden input addressable by its label", () => {
    render(<FileInput customFieldId="cf-1" />);

    const input = screen.getByLabelText<HTMLInputElement>("Upload files");
    expect(input.type).toBe("file");
    expect(input.multiple).toBe(true);
  });
});
