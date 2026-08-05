// @vitest-environment happy-dom
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

// Show is imported statically rather than lazily: it pulls in typia plus the whole ui component
// tree, and transforming that graph inside a hook exceeds vitest's default hookTimeout.
// See DownloadPage.test.tsx.
import Show from "$app/pages/Purchases/DisputeEvidence/Show";

import { showAlert } from "$app/components/server-components/Alert";
import { UserAgentProvider } from "$app/components/UserAgent";

type PendingUpload = (signedId: string) => void;

// getByRole returns HTMLElement, and `assertionStyle: "never"` rules out casting it. Narrowing
// through querySelector keeps the .checked / .value reads typed.
const asInput = (element: HTMLElement): HTMLInputElement => {
  const input = element.closest("input") ?? element.querySelector("input");
  if (!input) throw new Error(`expected an input, got ${element.tagName}`);
  return input;
};

const asTextArea = (element: HTMLElement): HTMLTextAreaElement => {
  const textarea = element.closest("textarea") ?? element.querySelector("textarea");
  if (!textarea) throw new Error(`expected a textarea, got ${element.tagName}`);
  return textarea;
};

const mocks = vi.hoisted(() => ({
  usePage: vi.fn(),
  put: vi.fn(),
  // Each queued DirectUpload parks its callback here so a test can finish uploads one at a time
  // and observe the page while a later one is still pending.
  pendingUploads: new Array<(signedId: string) => void>(),
}));

vi.mock("@inertiajs/react", () => ({
  usePage: mocks.usePage,
  useForm: <T,>(initial: T) => {
    const [data, setDataState] = React.useState(initial);
    const transformRef = React.useRef<(d: T) => unknown>((d) => d);
    return {
      data,
      processing: false,
      setData: (key: keyof T, value: T[keyof T]) => setDataState((prev) => ({ ...prev, [key]: value })),
      transform: (fn: (d: T) => unknown) => {
        transformRef.current = fn;
      },
      put: (url: string) => {
        mocks.put(url, transformRef.current(data));
      },
    };
  },
}));

vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    constructor(private file: File) {}
    create(callback: (error: unknown, blob?: unknown) => void) {
      mocks.pendingUploads.push((signedId: string) =>
        callback(null, {
          byte_size: this.file.size,
          filename: this.file.name,
          key: signedId,
          signed_id: signedId,
        }),
      );
    }
  },
}));

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const pageProps = {
  dispute_evidence: {
    dispute_reason: "product_not_received",
    customer_email: "buyer@example.com",
    purchased_at: "2026-07-01T00:00:00Z",
    duration_left_to_submit_evidence_formatted: "15 days",
    seller_response_due_at: "2026-07-16T00:00:00Z",
    customer_communication_file_max_size: 5 * 1024 * 1024,
    customer_communication_files_max_count: 10,
    blobs: { receipt_image: null, policy_image: null, customer_communication_file: null },
    saved: { reason_for_winning: null, cancellation_rebuttal: null, refund_refusal_explanation: null },
  },
  disputable: {
    purchase_for_dispute_evidence_id: "purchase-1",
    formatted_display_price: "$545",
    is_subscription: false,
  },
  products: [{ url: "https://example.gumroad.com/l/thing", name: "Thing" }],
};

const submitButton = () => screen.getByRole("button", { name: "Save response" });

// The rows render the filename as "<n>. <name>" split across text nodes, and InlineList also emits
// <li>, so read the row headings rather than list items.
const queuedFileNames = () => screen.queryAllByRole("heading", { level: 4 }).map((h) => h.textContent.trim());

const renderPage = () =>
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <Show />
    </UserAgentProvider>,
  );

const selectFiles = async (count: number, expectedPendingUploads = 1) => {
  const input = document.querySelector<HTMLInputElement>('input[type="file"]');
  if (!input) throw new Error("file input not rendered");
  const files = Array.from(
    { length: count },
    (_, i) => new File(["x"], `evidence-${i + 1}.png`, { type: "image/png" }),
  );
  Object.defineProperty(input, "files", { value: files, configurable: true });
  input.dispatchEvent(new Event("change", { bubbles: true }));
  await waitFor(() => expect(mocks.pendingUploads.length).toBe(expectedPendingUploads));
};

const finishNextUpload = (signedId: string) => {
  const finish: PendingUpload | undefined = mocks.pendingUploads.shift();
  if (!finish) throw new Error("no upload pending");
  act(() => finish(signedId));
};

describe("DisputeEvidence Show", () => {
  beforeEach(() => {
    Object.assign(globalThis, {
      Routes: {
        purchase_dispute_evidence_path: (id: string) => `/purchases/${id}/dispute_evidence`,
        rails_direct_uploads_path: () => "/rails/active_storage/direct_uploads",
        s3_utility_cdn_url_for_blob_path: ({ key }: { key: string }) => `/cdn/${key}`,
      },
    });
    mocks.usePage.mockReturnValue({ props: pageProps });
    mocks.pendingUploads.length = 0;
    mocks.put.mockClear();
    vi.mocked(showAlert).mockClear();
  });

  afterEach(cleanup);

  it("keeps submission disabled until every queued upload finishes, so the one-shot submit carries all files", async () => {
    renderPage();
    await selectFiles(2);

    // First file lands, second is still in flight. Submit used to be enabled in this window and
    // would PUT only the completed blob id, spending the single Stripe submission on half the packet.
    finishNextUpload("signed-first");
    await waitFor(() => expect(queuedFileNames()).toEqual(["1. evidence-1.png"]));
    expect(submitButton().hasAttribute("disabled")).toBe(true);

    finishNextUpload("signed-second");
    await waitFor(() => expect(submitButton().hasAttribute("disabled")).toBe(false));
    expect(queuedFileNames()).toEqual(["1. evidence-1.png", "2. evidence-2.png"]);

    act(() => submitButton().click());
    const confirm = await screen.findByRole("button", { name: "Confirm and save" });
    act(() => confirm.click());

    await waitFor(() => expect(mocks.put).toHaveBeenCalledTimes(1));
    expect(mocks.put.mock.calls[0]?.[1]).toMatchObject({
      dispute_evidence: { customer_communication_file_signed_blob_ids: ["signed-first", "signed-second"] },
    });
  });

  // A seller returning mid-window must be able to revise what they saved, not just read it back.
  it("restores a saved radio choice into the form and resends it untouched", async () => {
    mocks.usePage.mockReturnValue({
      props: {
        ...pageProps,
        dispute_evidence: {
          ...pageProps.dispute_evidence,
          saved: {
            reason_for_winning: "The cardholder received the product or service",
            cancellation_rebuttal: null,
            refund_refusal_explanation: null,
          },
        },
      },
    });
    renderPage();

    const restored = await screen.findByRole("radio", { name: "The cardholder received the product or service" });
    expect(asInput(restored).checked).toBe(true);
    expect(asInput(screen.getByRole("radio", { name: "The cardholder withdrew the dispute" })).checked).toBe(false);

    act(() => submitButton().click());
    act(() => screen.getByRole("button", { name: "Confirm and save" }).click());

    await waitFor(() => expect(mocks.put).toHaveBeenCalledTimes(1));
    expect(mocks.put.mock.calls[0]?.[1]).toMatchObject({
      dispute_evidence: { reason_for_winning: "The cardholder received the product or service" },
    });
  });

  // Free text and text with no matching radio both have to land in the editable "Other" textarea:
  // an option retired since the seller answered would otherwise strand their statement.
  it("restores unmatched saved text into the Other textarea", async () => {
    mocks.usePage.mockReturnValue({
      props: {
        ...pageProps,
        dispute_evidence: {
          ...pageProps.dispute_evidence,
          saved: {
            reason_for_winning: "The buyer downloaded the file twice",
            cancellation_rebuttal: null,
            refund_refusal_explanation: null,
          },
        },
      },
    });
    renderPage();

    expect(asInput(await screen.findByRole("radio", { name: "Other" })).checked).toBe(true);
    const textarea = screen.getByRole("textbox");
    expect(asTextArea(textarea).value).toBe("The buyer downloaded the file twice");
  });

  it("preselects nothing when the seller has not answered yet", () => {
    renderPage();

    expect(screen.queryAllByRole("radio").some((radio) => asInput(radio).checked)).toBe(false);
    expect(screen.queryByText("Your saved response is filled in below.")).toBe(null);
  });

  // The server folds the previously saved attachment into the merge before enforcing the max,
  // so on a return visit the UI must count it too — otherwise it permits a selection the server
  // is guaranteed to reject with "You can attach up to N files."
  describe("with a previously saved attachment", () => {
    const savedBlobProps = {
      ...pageProps,
      dispute_evidence: {
        ...pageProps.dispute_evidence,
        customer_communication_files_max_count: 3,
        blobs: {
          receipt_image: null,
          policy_image: null,
          customer_communication_file: {
            byte_size: 1024,
            filename: "customer_communication.pdf",
            key: "saved-key",
            signed_id: null,
            title: "Customer communication",
          },
        },
      },
    };

    beforeEach(() => {
      mocks.usePage.mockReturnValue({ props: savedBlobProps });
    });

    it("rejects a selection that only fits when the saved file is ignored", async () => {
      renderPage();
      await selectFiles(3, 0);

      await waitFor(() => expect(showAlert).toHaveBeenCalledWith("You can attach 2 more files.", "error"));
      expect(mocks.pendingUploads.length).toBe(0);
      expect(queuedFileNames()).toEqual(["Customer communication"]);
    });

    it("accepts a selection filling exactly the remaining slots and submits it", async () => {
      renderPage();
      await selectFiles(2);

      finishNextUpload("signed-first");
      await waitFor(() => expect(mocks.pendingUploads.length).toBe(1));
      finishNextUpload("signed-second");
      await waitFor(() => expect(submitButton().hasAttribute("disabled")).toBe(false));

      // 1 saved + 2 new = exactly the max of 3; the upload button disappears at zero remaining.
      expect(screen.queryByRole("button", { name: /Upload customer communication/u })).toBe(null);
      expect(showAlert).not.toHaveBeenCalled();

      act(() => submitButton().click());
      const confirm = await screen.findByRole("button", { name: "Confirm and save" });
      act(() => confirm.click());

      await waitFor(() => expect(mocks.put).toHaveBeenCalledTimes(1));
      expect(mocks.put.mock.calls[0]?.[1]).toMatchObject({
        dispute_evidence: { customer_communication_file_signed_blob_ids: ["signed-first", "signed-second"] },
      });
    });

    it("hides the upload input when the saved file alone exhausts the max", () => {
      mocks.usePage.mockReturnValue({
        props: {
          ...savedBlobProps,
          dispute_evidence: { ...savedBlobProps.dispute_evidence, customer_communication_files_max_count: 1 },
        },
      });
      renderPage();

      expect(document.querySelector('input[type="file"]')).toBe(null);
      expect(queuedFileNames()).toEqual(["Customer communication"]);
    });
  });
});
