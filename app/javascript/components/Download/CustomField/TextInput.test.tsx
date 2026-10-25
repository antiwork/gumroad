// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { TextInput } from "$app/components/Download/CustomField/TextInput";
import { showAlert } from "$app/components/server-components/Alert";

const saved = vi.hoisted(() => ({ type: "shortAnswer", value: "Saved answer" }));
vi.mock("$app/components/DownloadPage/WithContent", () => ({
  usePurchaseInfo: () => ({ purchaseId: "purchase", token: "token" }),
  usePurchaseCustomFields: () => [{ custom_field_id: "field", ...saved }],
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

beforeEach(() => {
  vi.stubGlobal("Routes", { purchase_custom_fields_path: () => "/purchase_custom_fields" });
  vi.stubGlobal(
    "fetch",
    vi.fn().mockImplementation(() => Promise.resolve(new Response(null, { status: 204 }))),
  );
});
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
  vi.unstubAllGlobals();
});

describe.each(["shortAnswer", "longAnswer"] as const)("%s save recovery", (type) => {
  const mount = () => {
    saved.type = type;
    render(<TextInput customFieldId="field" type={type} label="Response" />);
    return screen.getByLabelText<HTMLInputElement | HTMLTextAreaElement>("Response");
  };

  it.each([400, 401, 403, 404, 409, 422, 429, 500, 503])(
    "retains the answer and permits unchanged retry after HTTP %i",
    async (status) => {
      vi.mocked(fetch).mockResolvedValueOnce(new Response(null, { status }));
      const input = mount();
      fireEvent.change(input, { target: { value: "New answer" } });
      fireEvent.blur(input);
      await waitFor(() => expect(input.disabled).toBe(false));
      expect(input.value).toBe("New answer");
      expect(showAlert).toHaveBeenCalledWith("Your response could not be saved. Please try again.", "error");
      expect(showAlert).not.toHaveBeenCalledWith("Response saved!", "success");
      fireEvent.blur(input);
      await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Response saved!", "success"));
      expect(fetch).toHaveBeenCalledTimes(2);
      const payloads = vi.mocked(fetch).mock.calls.map(([, options]) => JSON.parse(String(options?.body)));
      expect(payloads).toEqual(
        Array(2).fill({ purchase_id: "purchase", custom_field_id: "field", value: "New answer", token: "token" }),
      );
      fireEvent.blur(input);
      expect(fetch).toHaveBeenCalledTimes(2);
    },
  );

  it("releases the field after a network failure", async () => {
    vi.mocked(fetch).mockRejectedValueOnce(new TypeError("Network unavailable"));
    const input = mount();
    fireEvent.change(input, { target: { value: "Unsaved answer" } });
    fireEvent.blur(input);
    await waitFor(() => expect(input.disabled).toBe(false));
    expect(input.value).toBe("Unsaved answer");
    expect(showAlert).toHaveBeenCalledWith("Your response could not be saved. Please try again.", "error");
  });

  it("skips unchanged saved answers and saves an edit once", async () => {
    const input = mount();
    fireEvent.blur(input);
    expect(fetch).not.toHaveBeenCalled();
    fireEvent.change(input, { target: { value: "Updated answer" } });
    fireEvent.blur(input);
    await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Response saved!", "success"));
    fireEvent.blur(input);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("disables editing only while the save is pending", async () => {
    let complete!: (response: Response) => void;
    vi.mocked(fetch).mockReturnValueOnce(
      new Promise((resolve) => {
        complete = resolve;
      }),
    );
    const input = mount();
    fireEvent.change(input, { target: { value: "Pending answer" } });
    fireEvent.blur(input);
    expect(input.disabled).toBe(true);
    await act(async () => complete(new Response(null, { status: 204 })));
    expect(input.disabled).toBe(false);
  });
});
