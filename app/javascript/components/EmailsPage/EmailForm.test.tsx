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
// happy-dom's DOMSerializer drops the text out of a ProseMirror fragment, so the real helper
// returns an empty paragraph here; the send path needs the message the editor actually holds.
vi.mock("$app/components/RichTextEditor", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/components/RichTextEditor")>();
  return { ...actual, serializeEditorContentToHTML: (editor: { getHTML: () => string }) => editor.getHTML() };
});
// The upsell card's node view fetches its product; the guard only reads the card's serialized HTML.
vi.mock("$app/components/TiptapExtensions/UpsellCard", async (importOriginal) => {
  const actual = await importOriginal<typeof import("$app/components/TiptapExtensions/UpsellCard")>();
  return { UpsellCard: actual.UpsellCard.extend({ addNodeView: null }) };
});
type UploadCallback = (error: Error | null, blob: { key: string }) => void;
const uploads = vi.hoisted((): { pending: UploadCallback[] } => ({ pending: [] }));
vi.mock("@rails/activestorage", () => ({
  DirectUpload: class {
    create(callback: UploadCallback) {
      uploads.pending.push(callback);
    }
  },
}));
type SaveOptions = {
  onFinish?: () => void;
  onBeforeUpdate?: (page: { props: Record<string, unknown> }) => void;
  onSuccess?: (page: { props: Record<string, unknown> }) => void;
};
// The unsaved-changes guard reads the save's response, so the stubbed request hands its callbacks
// back instead of only finishing the visit.
const saves = vi.hoisted((): SaveOptions[] => []);
const post = vi.hoisted(() =>
  vi.fn((_url: string, options?: SaveOptions) => {
    saves.push(options ?? {});
    options?.onFinish?.();
  }),
);
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
const beforeListeners = vi.hoisted((): ((e: unknown) => void)[] => []);
const sent = vi.hoisted((): { payload: SentPayload | null } => ({ payload: null }));
vi.mock("@inertiajs/react", () => ({
  Link: ({
    href,
    children,
    onClick,
  }: {
    href: string;
    children?: React.ReactNode;
    onClick?: React.MouseEventHandler;
  }) => (
    <a href={href} onClick={onClick}>
      {children}
    </a>
  ),
  usePage: () => ({ url: "/emails/new", props: {} }),
  router: {
    visit: () => {},
    on: (_event: string, handler: (e: unknown) => void) => {
      beforeListeners.push(handler);
      return () => {
        beforeListeners.splice(beforeListeners.indexOf(handler), 1);
      };
    },
  },
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
      put: post,
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

const formTree = (
  installment: Installment | null = null,
  formContext: InstallmentFormContext = context,
  singleCustomerRecipient: { purchase_id: string; email: string } | null = null,
) => (
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
      <EmailForm context={formContext} installment={installment} singleCustomerRecipient={singleCustomerRecipient} />
    </CurrentSellerProvider>
  </DomainSettingsProvider>
);
const renderForm = (...args: Parameters<typeof formTree>) => render(formTree(...args));

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
  saves.length = 0;
  sent.payload = null;
  window.history.replaceState({}, "", "/");
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

  it("starts a new post in the sections that take new posts by default", () => {
    renderForm(null, {
      ...context,
      profile_sections: [
        { id: "default-on", name: "Read Posts", add_new_posts: true },
        { id: "default-off", name: "Archive", add_new_posts: false },
      ],
    });

    expect(screen.getByRole("switch", { name: "Read Posts" })).toHaveProperty("checked", true);
    expect(screen.getByRole("switch", { name: "Archive" })).toHaveProperty("checked", false);
  });
});

describe("EmailForm unsaved-changes guard", () => {
  const unload = () => {
    const event = new Event("beforeunload", { cancelable: true });
    window.dispatchEvent(event);
    return event.defaultPrevented;
  };
  const visit = () => {
    const event = { detail: { visit: { method: "get" } }, preventDefault: vi.fn() };
    beforeListeners.forEach((listener) => listener(event));
    return event.preventDefault.mock.calls.length > 0;
  };
  // The baseline is taken once the message editor mounts, so an edit fired before that is
  // baselined as clean. Retype until the guard reports the edit, which cannot happen before the
  // baseline exists: a fixed wait loses the race whenever the mount is slow.
  const edit = async () => {
    const title = await screen.findByPlaceholderText("Title");
    for (let version = 1; version <= 50; version++) {
      fireEvent.change(title, { target: { value: `Edited ${version}` } });
      if (unload()) return;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error("the unsaved-changes guard never warned about an edit");
  };

  afterEach(() => vi.stubGlobal("confirm", undefined));

  it("does not warn before anything is edited", async () => {
    renderForm();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(unload()).toBe(false);
    expect(visit()).toBe(false);
  });

  it("warns on tab close and in-app navigation once edited, and honors the confirm answer", async () => {
    renderForm();
    await edit();
    expect(unload()).toBe(true);
    const confirm = vi.fn(() => false);
    vi.stubGlobal("confirm", confirm);
    expect(visit()).toBe(true);
    confirm.mockImplementation(() => true);
    expect(visit()).toBe(false);
  });

  it("confirms on Cancel and stays when declined, and does not double prompt when accepted", async () => {
    renderForm();
    await edit();
    const confirm = vi.fn(() => false);
    vi.stubGlobal("confirm", confirm);
    expect(fireEvent.click(screen.getByRole("link", { name: "Cancel" }))).toBe(false);
    confirm.mockImplementation(() => true);
    expect(fireEvent.click(screen.getByRole("link", { name: "Cancel" }))).toBe(true);
    confirm.mockClear();
    expect(visit()).toBe(false);
    expect(confirm).not.toHaveBeenCalled();
  });

  // `save` resolves on a microtask, so the request's callbacks only exist after a tick.
  const save = async () => {
    const sent = saves.length;
    fireEvent.click(screen.getByRole("button", { name: "Save" }));
    await waitFor(() => expect(saves.length).toBe(sent + 1));
    return assertDefined(saves.at(-1));
  };
  const saved = { props: { flash: { message: "Changes saved!", status: "success" } } };
  const rejected = { props: { flash: { message: "Please provide a valid date and time.", status: "danger" } } };

  // What the server sends back after a save, which can differ from what was sent.
  const savedRecord: Installment = {
    external_id: "email-1",
    display_type: "draft",
    name: "Edited",
    message: "<p>Saved by the server</p>",
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
    full_url: "https://seller.gumroad.com/p/edited",
    has_been_blasted: false,
    files: [],
  };
  // The order Inertia runs a preserveState response in: onBeforeUpdate, the props swap, onSuccess.
  const respond = (
    view: ReturnType<typeof renderForm>,
    request: SaveOptions,
    page: typeof saved,
    record: Installment | null,
  ) => {
    request.onBeforeUpdate?.(page);
    view.rerender(formTree(record));
    request.onSuccess?.(page);
  };

  it("stops warning once the saved record arrives, even when the server changed it", async () => {
    const view = renderForm();
    await edit();
    const request = await save();
    expect(unload()).toBe(true);
    respond(view, request, saved, savedRecord);
    await waitFor(() => expect(screen.getByLabelText("Email message").textContent).toBe("Saved by the server"));
    await waitFor(() => expect(unload()).toBe(false));
  });

  it("does not warn after saving a new publish date on a published email", async () => {
    const published: Installment = { ...savedRecord, display_type: "published", published_at: "2026-08-01T12:00:00Z" };
    const view = renderForm(published);
    const date = await screen.findByPlaceholderText<HTMLInputElement>("Publish date");
    // The baseline is taken in a timeout after the editor settles, so a change fired before that is
    // baselined as clean — and the mount is slow enough on CI to lose any fixed wait. Retype until
    // the guard reports the edit, which cannot happen before the baseline exists.
    for (let day = 1; day <= 28; day++) {
      fireEvent.change(date, { target: { value: `2026-07-${String(day).padStart(2, "0")}` } });
      if (unload()) break;
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    fireEvent.change(date, { target: { value: "2026-07-15" } });
    expect(unload()).toBe(true);

    respond(view, await save(), saved, { ...published, published_at: "2026-07-15T12:00:00Z" });
    await waitFor(() => expect(screen.getByPlaceholderText<HTMLInputElement>("Publish date").value).toBe("2026-07-15"));
    await waitFor(() => expect(unload()).toBe(false));
  });

  it("does not warn after saving a new upsell card that the server gave an id", async () => {
    const card = '<upsell-card productid="product-1"></upsell-card>';
    const draft = { ...savedRecord, message: `<p>Hi</p>${card}` };
    const view = renderForm(draft);
    await edit();

    const withId = '<upsell-card productid="product-1" id="upsell-1"></upsell-card>';
    respond(view, await save(), saved, { ...draft, message: `<p>Hi</p>${withId}` });
    await waitFor(() => expect(document.querySelector("upsell-card#upsell-1")).not.toBeNull());
    await waitFor(() => expect(unload()).toBe(false));
  });

  it("keeps warning after a rejected save, and for an edit the save did not carry", async () => {
    const view = renderForm();
    await edit();
    respond(view, await save(), rejected, null);
    expect(unload()).toBe(true);

    const request = await save();
    // Typed while the request is in flight, so it is not part of what that request saved.
    fireEvent.change(screen.getByPlaceholderText("Title"), { target: { value: "Edited again" } });
    respond(view, request, saved, savedRecord);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(unload()).toBe(true);
  });

  it("does not ask on a modified click of Cancel, which opens a new tab", async () => {
    renderForm();
    await edit();
    const confirm = vi.fn(() => true);
    vi.stubGlobal("confirm", confirm);
    fireEvent.click(screen.getByRole("link", { name: "Cancel" }), { metaKey: true });
    expect(confirm).not.toHaveBeenCalled();
    expect(unload()).toBe(true);
  });

  it("treats a changed schedule date as an unsaved edit", async () => {
    renderForm();
    fireEvent.click(screen.getByRole("button", { name: "Publish" }));
    const scheduleDate = await screen.findByLabelText("Schedule date");
    expect(unload()).toBe(false);
    // Same baseline race as the publish date above: retype until the guard reports the edit.
    for (let minute = 0; minute <= 27 && !unload(); minute++) {
      fireEvent.change(scheduleDate, { target: { value: `2030-01-01T10:${String(minute).padStart(2, "0")}` } });
      fireEvent.focusOut(scheduleDate);
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(unload()).toBe(true);
  });

  it("does not warn after the email is sent to the single customer", async () => {
    window.history.replaceState({}, "", "/new_email_path?template=single_customer&purchase_id=p1");
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
    renderForm(draft, { ...context, audience_types: ["customers"] }, { purchase_id: "p1", email: "buyer@example.com" });

    await edit();
    expect(unload()).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "Send now" }));
    await waitFor(() => expect(unload()).toBe(false));
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
