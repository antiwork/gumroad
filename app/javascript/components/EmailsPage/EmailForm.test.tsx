// @vitest-environment happy-dom
//
// The email editor's Save button reads the shared image-upload guard; the guard has to stay up
// until the CDN URL resolves, because the editor holds a blob: preview until then and the
// sanitizer drops blob: srcs from a saved body.
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { type Installment, type InstallmentFormContext } from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { EmailForm } from "$app/components/EmailsPage/EmailForm";

// The component reads `Routes` at module scope, so the globals have to exist before it is imported.
// The CDN URL lookup can be held open so the window between "blob uploaded" and "CDN URL resolved"
// is observable.
const recipientCountFilters = vi.hoisted((): unknown[] => []);
const cdn = vi.hoisted(() => {
  const state: { hold: boolean; release: (() => void)[] } = { hold: false, release: [] };
  vi.stubGlobal("SSR", false);
  // Each route helper returns its own name, so the fetch stub can tell the CDN lookup apart from
  // the form's recipient-count and upsell-product requests.
  vi.stubGlobal(
    "Routes",
    new Proxy(
      {},
      {
        get:
          (_, name: string) =>
          (...args: unknown[]) => {
            if (name === "internal_installment_recipient_count_path") recipientCountFilters.push(args[0]);
            return `/${name}`;
          },
      },
    ),
  );
  const json = (body: unknown) =>
    new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
  vi.stubGlobal("fetch", (url: string) => {
    if (!url.includes("s3_utility_cdn_url_for_blob_path")) {
      if (url.includes("recipient_count")) return Promise.resolve(json({ recipient_count: 0, audience_count: 0 }));
      return Promise.resolve(json([]));
    }
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
const post = vi.hoisted(() => vi.fn((_url: string, options?: { onFinish?: () => void }) => options?.onFinish?.()));
const savedDraft = vi.hoisted(() => vi.fn());
vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children?: React.ReactNode }) => <a href={href}>{children}</a>,
  usePage: () => ({ url: "/emails/new", props: {} }),
  router: { visit: () => {}, on: () => () => {} },
  useForm: (initial: { installment: { name: string; message: string } }) => {
    const [data, setDataState] = React.useState(initial);
    let transform = (): unknown => data;
    return {
      data,
      // Inertia's setData takes a dotted path (`installment.name`).
      setData: (key: string, value: string) =>
        setDataState((prev) => ({ installment: { ...prev.installment, [key.replace("installment.", "")]: value } })),
      processing: false,
      transform: (callback: () => unknown) => {
        transform = callback;
      },
      post,
      put: (url: string, options?: { onFinish?: () => void }) => {
        savedDraft(url, transform());
        options?.onFinish?.();
      },
    };
  },
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

const context: InstallmentFormContext = {
  audience_types: ["everyone"],
  products: [],
  affiliate_products: [],
  timezone: "UTC",
  currency_type: "usd",
  countries: [],
  profile_sections: [],
  has_scheduled_emails: false,
  aws_access_key_id: "key",
  s3_url: "https://s3.example/bucket",
  user_id: "1",
  allow_comments_by_default: true,
  from_tab: null,
};

const renderForm = (overrides: { context?: InstallmentFormContext; installment?: Installment | null } = {}) =>
  render(
    <DomainSettingsProvider
      value={{
        scheme: "https",
        appDomain: "app.gumroad.com",
        rootDomain: "gumroad.com",
        shortDomain: "gum.co",
        discoverDomain: "discover.gumroad.com",
        thirdPartyAnalyticsDomain: "gumroad.com",
        apiDomain: "api.gumroad.com",
      }}
    >
      <CurrentSellerProvider value={seller}>
        <EmailForm context={overrides.context ?? context} installment={overrides.installment ?? null} />
      </CurrentSellerProvider>
    </DomainSettingsProvider>,
  );

const pasteImage = (container: HTMLElement) =>
  fireEvent.paste(assertDefined(container.querySelector('[aria-label="Email message"]')), {
    clipboardData: { files: [new File(["pixels"], "photo.png", { type: "image/png" })] },
  });

const saveDisabled = () => screen.getByRole<HTMLButtonElement>("button", { name: "Save" }).disabled;

beforeEach(() => {
  uploads.pending.length = 0;
  cdn.hold = false;
  cdn.release.length = 0;
  post.mockClear();
  savedDraft.mockClear();
  recipientCountFilters.length = 0;
});

afterEach(cleanup);

describe("EmailForm", () => {
  it("keeps mixed product and variant exclusions when a saved draft is reopened", async () => {
    renderForm({
      context: {
        ...context,
        audience_types: ["everyone", "customers"],
        products: [
          { permalink: "product-a", name: "Product A", archived: false, variants: [] },
          {
            permalink: "product-b",
            name: "Product B",
            archived: false,
            variants: [{ id: "variant-b", name: "Version B" }],
          },
        ],
      },
      installment: {
        external_id: "draft-1",
        display_type: "draft",
        name: "Filtered draft",
        message: "<p>Hello</p>",
        published_at: null,
        updated_at: "2026-10-06T00:00:00Z",
        stream_only: false,
        streamable: false,
        send_emails: true,
        shown_on_profile: false,
        installment_type: "seller",
        not_bought_products: ["product-a"],
        not_bought_variants: ["variant-b"],
        paid_more_than_cents: null,
        paid_less_than_cents: null,
        allow_comments: true,
        full_url: "https://seller.example.com/p/filtered-draft",
        has_been_blasted: false,
        files: [],
      },
    });

    expect(screen.getByText("Product A")).not.toBeNull();
    expect(screen.getByText("Product B - Version B")).not.toBeNull();
    await waitFor(() =>
      expect(recipientCountFilters.at(-1)).toMatchObject({
        not_bought_products: ["product-a"],
        not_bought_variants: ["variant-b"],
      }),
    );
    fireEvent.change(screen.getByPlaceholderText("Title"), { target: { value: "Renamed draft" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() =>
      expect(savedDraft).toHaveBeenCalledWith(
        "/email_path",
        expect.objectContaining({
          installment: expect.objectContaining({
            name: "Renamed draft",
            not_bought_products: ["product-a"],
            not_bought_variants: ["variant-b"],
          }),
        }),
      ),
    );
  });

  it("does not let the publish countdown save while an image is still uploading", async () => {
    const { container } = renderForm();
    fireEvent.change(screen.getByPlaceholderText("Title"), { target: { value: "Hello" } });
    // The countdown starts while nothing is uploading, so the Publish controls are enabled.
    fireEvent.click(screen.getByRole("button", { name: "Publish" }));
    fireEvent.click(await screen.findByRole("button", { name: "Publish now" }));
    await screen.findByText(/Publishing in/u);

    // An image pasted mid-countdown is still on its blob: src when the countdown fires `save`.
    cdn.hold = true;
    pasteImage(container);
    await waitFor(() => expect(uploads.pending).toHaveLength(1));
    assertDefined(uploads.pending.shift())(null, { key: "blob-key" });
    await waitFor(() => expect(cdn.release).toHaveLength(1));

    await waitFor(() => expect(screen.queryByText(/Publishing in/u)).toBeNull(), { timeout: 4000 });
    expect(post).not.toHaveBeenCalled();
  });

  it("keeps Save disabled until an uploaded image has its CDN URL, not just its blob", async () => {
    const { container } = renderForm();
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
