// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

const purchaseInfo = { purchaseId: "purchase-1", token: "token-1" };
const purchaseCustomFields: { custom_field_id: string; type: string; files: unknown[] }[] = [];

vi.mock("$app/components/DownloadPage/WithContent", () => ({
  usePurchaseInfo: () => purchaseInfo,
  usePurchaseCustomFields: () => purchaseCustomFields,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/utils/request", () => ({ request: vi.fn() }));

import { FileInput } from "$app/components/Download/CustomField/FileInput";

afterEach(cleanup);

describe("FileInput upload control", () => {
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
