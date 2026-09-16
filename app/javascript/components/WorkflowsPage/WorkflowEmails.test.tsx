// @vitest-environment happy-dom
//
// The workflow emails editor's Save button reads the shared image-upload guard; the guard has to
// stay up until the CDN URL resolves, because the editor holds a blob: preview until then and the
// sanitizer drops blob: srcs from a saved body.
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { type Workflow, type WorkflowFormContext } from "$app/types/workflow";
import { assertDefined } from "$app/utils/assert";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import WorkflowEmails from "$app/components/WorkflowsPage/WorkflowEmails";

// The CDN URL lookup can be held open so the window between "blob uploaded" and "CDN URL resolved"
// is observable.
const cdn = vi.hoisted(() => {
  const state: { hold: boolean; release: (() => void)[] } = { hold: false, release: [] };
  vi.stubGlobal("SSR", false);
  // Each route helper returns its own name, so the fetch stub can tell the CDN lookup apart from
  // the editor's upsell-product request.
  vi.stubGlobal("Routes", new Proxy({}, { get: (_, name: string) => () => `/${name}` }));
  const json = (body: unknown) =>
    new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
  vi.stubGlobal("fetch", (url: string) => {
    if (!url.includes("s3_utility_cdn_url_for_blob_path")) return Promise.resolve(json([]));
    const response = () => json({ url: "https://cdn.example/image.png" });
    if (!state.hold) return Promise.resolve(response());

    return new Promise<Response>((resolve) => state.release.push(() => resolve(response())));
  });
  return state;
});
vi.mock("$app/utils/prepareImageForUpload", () => ({
  isLikelyImageFile: () => true,
  prepareImageForUpload: async (file: File) => file,
  heicDecodingLikely: () => false,
}));
type UploadCallback = (error: Error | null, blob: { key: string }) => void;
const uploads = vi.hoisted((): { pending: UploadCallback[] } => ({ pending: [] }));
vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: UploadCallback) {
      uploads.pending.push(callback);
    }
  },
}));
vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children?: React.ReactNode }) => <a href={href}>{children}</a>,
  usePage: () => ({ url: "/workflows/workflow-1/emails", props: {} }),
  useForm: () => ({ processing: false, transform: () => {}, patch: () => {} }),
}));
// The preview pane frames the workflow's public URL; letting it load pulls in an iframe fetch
// happy-dom reports as an unhandled rejection.
vi.mock("$app/components/PreviewSidebar", () => ({
  WithPreviewSidebar: ({ children }: { children: React.ReactNode }) => children,
  PreviewSidebar: () => null,
  PreviewChrome: ({ children }: { children: React.ReactNode }) => children,
}));
vi.mock("$app/components/useConfigureEvaporate", () => ({
  useConfigureEvaporate: () => ({ evaporateUploader: {}, s3UploadConfig: {} }),
}));

const seller: CurrentSeller = {
  id: "1",
  email: "seller@example.com",
  name: "Seller",
  subdomain: "seller",
  avatarUrl: "",
  isBuyer: false,
  timeZone: { name: "UTC", offset: 0 },
  has_published_products: true,
  can_publish_products: true,
  publishBlockedReason: null,
  noPayoutRailInComplianceCountry: false,
  legalGuardianRequirementMet: false,
  legalGuardianUnsupported: false,
  isNameInvalidForEmailDelivery: false,
  profileBackgroundColor: "#ffffff",
  profileHighlightColor: "#000000",
  profileFont: "ABC Favorit",
};

const context: WorkflowFormContext = {
  products_and_variant_options: [],
  affiliate_product_options: [],
  timezone: "UTC",
  currency_symbol: "$",
  countries: [],
  aws_access_key_id: "key",
  s3_url: "https://s3.example/bucket",
  user_id: "1",
  gumroad_address: "548 Market St, San Francisco, CA 94104",
  email_from: "Seller <noreply@gumroad.com>",
  eligible_for_abandoned_cart_workflows: false,
};

const workflow: Workflow = {
  external_id: "workflow-1",
  name: "Welcome",
  workflow_type: "seller",
  workflow_trigger: null,
  published: false,
  first_published_at: null,
  send_to_past_customers: false,
  installments: [
    {
      external_id: "email-1",
      name: "Hello",
      message: "<p>Hello</p>",
      files: [],
      published_once_already: false,
      member_cancellation: false,
      stream_only: false,
      call_to_action_text: null,
      call_to_action_url: null,
      new_customers_only: false,
      streamable: false,
      sent_count: null,
      click_count: 0,
      open_count: 0,
      click_rate: null,
      open_rate: null,
      delayed_delivery_time_duration: 1,
      delayed_delivery_time_period: "hour",
      displayed_delayed_delivery_time_period: "1 hour",
    },
  ],
};

const renderEditor = () =>
  render(
    <CurrentSellerProvider value={seller}>
      <WorkflowEmails context={context} workflow={workflow} />
    </CurrentSellerProvider>,
  );

const pasteImage = (container: HTMLElement) =>
  fireEvent.paste(assertDefined(container.querySelector('[aria-label="Email message"]')), {
    clipboardData: { files: [new File(["pixels"], "photo.png", { type: "image/png" })] },
  });

const saveDisabled = () => screen.getByRole<HTMLButtonElement>("button", { name: "Save changes" }).disabled;

beforeEach(() => {
  uploads.pending.length = 0;
  cdn.hold = false;
  cdn.release.length = 0;
});

afterEach(cleanup);

describe("WorkflowEmails", () => {
  it("keeps Save changes disabled until an uploaded image has its CDN URL, not just its blob", async () => {
    const { container } = renderEditor();
    fireEvent.click(screen.getByRole("button", { name: "Edit" }));
    expect(saveDisabled()).toBe(false);

    cdn.hold = true;
    pasteImage(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(1));
    expect(saveDisabled()).toBe(true);

    // The blob is up, but the editor still shows the local blob: preview; a save now would persist
    // a body without the image.
    assertDefined(uploads.pending.shift())(null, { key: "blob-key" });
    await waitFor(() => expect(cdn.release).toHaveLength(1));
    expect(saveDisabled()).toBe(true);

    cdn.release.forEach((release) => release());
    await waitFor(() =>
      expect(container.querySelector("img")?.getAttribute("src")).toBe("https://cdn.example/image.png"),
    );
    expect(saveDisabled()).toBe(false);
  });
});
