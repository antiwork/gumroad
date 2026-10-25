// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { FileInput } from "$app/components/Download/CustomField/FileInput";
import { showAlert } from "$app/components/server-components/Alert";

vi.mock(
  "@boxicons/react",
  () =>
    new Proxy(
      {},
      {
        has: () => true,
        get: (_target, name) => (name === "then" ? undefined : () => null),
      },
    ),
);
vi.mock("$app/components/DownloadPage/WithContent", () => ({
  usePurchaseInfo: () => ({ purchaseId: "purchase-1", token: "token-1" }),
  usePurchaseCustomFields: () => [],
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/utils/request", () => ({ request: vi.fn() }));
vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: (error: string) => void) {
      callback("Connection interrupted");
    }
  },
}));
vi.stubGlobal("Routes", { rails_direct_uploads_path: () => "/direct_uploads" });
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

it.each([1, 11 * 1024 * 1024])(
  "clears a rejected %s-byte selection so the same file can be chosen again",
  async (size) => {
    render(<FileInput customFieldId="field-1" />);
    const input = screen.getByLabelText<HTMLInputElement>("Upload files");
    let pickerValue = "C:\\fakepath\\notes.txt";
    Object.defineProperty(input, "value", {
      configurable: true,
      get: () => pickerValue,
      set: (value: string) => {
        pickerValue = value;
      },
    });
    const file = new File(["x"], "notes.txt");
    Object.defineProperty(file, "size", { value: size });
    fireEvent.change(input, { target: { files: [file] } });
    await waitFor(() => expect(showAlert).toHaveBeenCalledOnce());
    expect(pickerValue).toBe("");
    expect(screen.getByRole<HTMLButtonElement>("button", { name: "Upload files" }).disabled).toBe(false);
  },
);
