// @vitest-environment happy-dom
//
// The email editor's Save button reads the shared image-upload guard; the guard has to stay up
// until the CDN URL resolves, because the editor holds a blob: preview until then and the
// sanitizer drops blob: srcs from a saved body.
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { getRecipientCount, type Installment, type InstallmentFormContext } from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";

import { CurrentSellerProvider, type CurrentSeller } from "$app/components/CurrentSeller";
import { DomainSettingsProvider } from "$app/components/DomainSettings";
import { EmailForm } from "$app/components/EmailsPage/EmailForm";

// The component reads `Routes` at module scope, so the globals have to exist before it is imported.
// The CDN URL lookup can be held open so the window between "blob uploaded" and "CDN URL resolved"
// is observable.
const cdn = vi.hoisted(() => {
  const state: { hold: boolean; release: (() => void)[] } = { hold: false, release: [] };
  vi.stubGlobal("SSR", false);
  // Each route helper returns its own name, so the fetch stub can tell the CDN lookup apart from
  // the form's recipient-count and upsell-product requests.
  vi.stubGlobal("Routes", new Proxy({}, { get: (_, name: string) => () => `/${name}` }));
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
vi.mock("$app/data/installments", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/data/installments")>();
  return { ...actual, getRecipientCount: vi.fn(actual.getRecipientCount) };
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
// The transform callback builds the payload Inertia would send; keeping it lets a test assert
// what the form would submit.
type SentPayload = {
  installment: {
    not_clicked_post_id: string | null;
    opened_post_id: string | null;
    not_bought_products: string[] | null;
    not_bought_variants: string[] | null;
  };
};
const sent = vi.hoisted((): { payload: SentPayload | null } => ({ payload: null }));
vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children?: React.ReactNode }) => <a href={href}>{children}</a>,
  usePage: () => ({ url: "/emails/new", props: {} }),
  router: { visit: () => {}, on: () => () => {} },
  useForm: (initial: { installment: { name: string; message: string } }) => {
    const [data, setDataState] = React.useState(initial);
    return {
      data,
      // Inertia's setData takes a dotted path (`installment.name`).
      setData: (key: string, value: string) =>
        setDataState((prev) => ({ installment: { ...prev.installment, [key.replace("installment.", "")]: value } })),
      processing: false,
      transform: (build: () => SentPayload) => {
        sent.payload = build();
      },
      post,
      put: () => {},
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
  waitlist_products: [],
  timezone: "UTC",
  currency_type: "usd",
  countries: [],
  profile_sections: [],
  has_scheduled_emails: false,
  emailed_posts: [],
  aws_access_key_id: "key",
  s3_url: "https://s3.example/bucket",
  user_id: "1",
  allow_comments_by_default: true,
  from_tab: null,
};

const renderForm = (installment: Installment | null = null, formContext: InstallmentFormContext = context) =>
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
        <EmailForm context={formContext} installment={installment} />
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
  sent.payload = null;
});

afterEach(cleanup);

describe("EmailForm", () => {
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

describe('EmailForm "Has not yet bought"', () => {
  const products: InstallmentFormContext["products"] = [
    {
      permalink: "product-1",
      name: "Design guide",
      archived: false,
      variants: [{ id: "variant-1", name: "Studio edition" }],
    },
    { permalink: "product-2", name: "Course", archived: false, variants: [] },
  ];
  const audienceContext: InstallmentFormContext = { ...context, products };

  const draft: Installment = {
    external_id: "email-1",
    display_type: "draft",
    name: "August update",
    message: "Hello",
    published_at: null,
    updated_at: "2026-08-01T00:00:00Z",
    stream_only: false,
    streamable: false,
    send_emails: true,
    shown_on_profile: false,
    installment_type: "audience",
    paid_more_than_cents: null,
    paid_less_than_cents: null,
    allow_comments: true,
    full_url: "https://seller.gumroad.com/p/august-update",
    has_been_blasted: false,
    files: [],
  };

  const exclusions = () => {
    const fieldset = screen.getByLabelText("Has not yet bought").closest("fieldset");
    if (!fieldset) throw new Error("Exclusion fieldset missing");
    return fieldset;
  };

  const selectExclusion = (fieldset: HTMLElement, label: string) => {
    // The menu mounts on focusin; its options live in a <datalist>, so they are queried by attribute.
    fireEvent.focusIn(within(fieldset).getByLabelText("Has not yet bought"));
    const option = [...fieldset.querySelectorAll('[role="option"]')].find((el) => el.textContent === label);
    if (!option) throw new Error(`${label} is not offered as an exclusion`);
    fireEvent.click(option);
  };

  it("restores both the saved products and the saved versions when editing", () => {
    renderForm({ ...draft, not_bought_products: ["product-1"], not_bought_variants: ["variant-1"] }, audienceContext);

    const fieldset = exclusions();
    expect(within(fieldset).getByRole("button", { name: "Design guide" })).not.toBeNull();
    expect(within(fieldset).getByRole("button", { name: "Design guide - Studio edition" })).not.toBeNull();
  });

  it("adds a second exclusion alongside one that is already selected", () => {
    renderForm({ ...draft, not_bought_products: ["product-1"] }, audienceContext);

    const fieldset = exclusions();
    selectExclusion(fieldset, "Course");

    expect(within(fieldset).getByRole("button", { name: "Design guide" })).not.toBeNull();
    expect(within(fieldset).getByRole("button", { name: "Course" })).not.toBeNull();
  });

  it("sends every selected product and version in the recipient count and the save payload", async () => {
    renderForm(draft, audienceContext);

    const fieldset = exclusions();
    selectExclusion(fieldset, "Design guide");
    selectExclusion(fieldset, "Course");
    selectExclusion(fieldset, "Design guide - Studio edition");

    const expected = { not_bought_products: ["product-1", "product-2"], not_bought_variants: ["variant-1"] };
    await waitFor(() => expect(vi.mocked(getRecipientCount).mock.lastCall?.[0]).toMatchObject(expected));

    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(sent.payload?.installment).toMatchObject(expected));
  });
});

describe('EmailForm "Has not clicked"', () => {
  const emailedContext: InstallmentFormContext = {
    ...context,
    audience_types: ["customers"],
    emailed_posts: [
      { external_id: "post-1", name: "September update" },
      { external_id: "post-2", name: "October update" },
    ],
  };

  const customersDraft: Installment = {
    external_id: "email-2",
    display_type: "draft",
    name: "Win-back",
    message: "Hello",
    published_at: null,
    updated_at: "2026-08-01T00:00:00Z",
    stream_only: false,
    streamable: false,
    send_emails: true,
    shown_on_profile: false,
    installment_type: "seller",
    paid_more_than_cents: null,
    paid_less_than_cents: null,
    allow_comments: true,
    full_url: "https://seller.gumroad.com/p/win-back",
    has_been_blasted: false,
    files: [],
  };

  const picker = () => screen.getByLabelText<HTMLSelectElement>("Has not clicked");

  it("offers the seller's emailed posts and restores the saved one", () => {
    renderForm({ ...customersDraft, not_clicked_post_id: "post-2" }, emailedContext);

    expect(picker().value).toBe("post-2");
    expect([...picker().options].map((option) => option.textContent)).toEqual([
      "Select…",
      "September update",
      "October update",
    ]);
  });

  it("submits the chosen post with the form", async () => {
    renderForm(customersDraft, emailedContext);

    fireEvent.change(picker(), { target: { value: "post-2" } });
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => expect(sent.payload?.installment.not_clicked_post_id).toBe("post-2"));
  });

  it("spells out the chosen post's full title under the picker", () => {
    renderForm(customersDraft, emailedContext);

    expect(screen.queryByText("October update", { selector: "p" })).toBeNull();

    fireEvent.change(picker(), { target: { value: "post-2" } });

    expect(screen.getByText("October update", { selector: "p" })).not.toBeNull();
  });

  it("colours the unset option like the placeholder it is", () => {
    renderForm(customersDraft, emailedContext);

    expect(picker().style.color).toBe("var(--color-muted)");

    fireEvent.change(picker(), { target: { value: "post-2" } });

    expect(picker().style.color).toBe("");
  });

  it("is not offered when the seller has no emailed posts", () => {
    renderForm(customersDraft, { ...emailedContext, emailed_posts: [] });

    expect(screen.queryByLabelText("Has not clicked")).toBeNull();
  });

  it("submits the chosen post as an opened filter, and labels it approximate", async () => {
    renderForm({ ...customersDraft, opened_post_id: "post-1" }, emailedContext);
    const opened = screen.getByLabelText<HTMLSelectElement>("Has opened (approximate)");
    expect(opened.value).toBe("post-1");

    fireEvent.change(opened, { target: { value: "post-2" } });
    expect(screen.getByText("October update", { selector: "p" })).not.toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Save" }));

    await waitFor(() => expect(sent.payload?.installment.opened_post_id).toBe("post-2"));
  });

  it("says a withheld recipient count is hidden for privacy, which is true whichever side is small", async () => {
    const actual = vi.mocked(getRecipientCount).getMockImplementation();
    vi.mocked(getRecipientCount).mockImplementation(() => ({
      response: Promise.resolve({ recipient_count: null, audience_count: 50 }),
      cancel: () => undefined,
    }));
    try {
      renderForm({ ...customersDraft, not_clicked_post_id: "post-1" }, emailedContext);

      expect((await screen.findByLabelText("Recipient count")).textContent).toBe("Hidden for privacy / 50");
    } finally {
      if (actual) vi.mocked(getRecipientCount).mockImplementation(actual);
    }
  });
});
