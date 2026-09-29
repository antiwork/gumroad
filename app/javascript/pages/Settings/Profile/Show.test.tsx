// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ProfileSettingsForm } from "$app/pages/Settings/Profile/profileSettingsForm";
// Imported statically: transforming typia plus the page's component tree inside a hook exceeds
// vitest's default hookTimeout.
import SettingsPage from "$app/pages/Settings/Profile/Show";

import { UserAgentProvider } from "$app/components/UserAgent";

vi.stubGlobal("SSR", false);
vi.stubGlobal(
  "Routes",
  new Proxy({}, { get: (_target, name: string) => () => `/${name.replace(/_path$|_url$/u, "")}` }),
);

// usePage reads from a store so router.reload can hand the page fresh server props, as Inertia does.
const page = vi.hoisted(() => {
  const listeners = new Set<() => void>();
  const state: { props: Record<string, unknown>; reloadProps: Record<string, unknown> | null } = {
    props: {},
    reloadProps: null,
  };
  return {
    state,
    set: (props: Record<string, unknown>) => {
      state.props = props;
      listeners.forEach((listener) => listener());
    },
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  };
});
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: React.useSyncExternalStore(page.subscribe, () => page.state.props) }),
  router: {
    on: () => () => {},
    reload: ({ onFinish }: { onFinish: () => void }) => {
      if (page.state.reloadProps) page.set(page.state.reloadProps);
      onFinish();
    },
  },
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));
const canUpdate = vi.hoisted(() => ({ current: true }));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { settings_profile: { update: canUpdate.current } } }),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
// The storefront inside the preview needs app-wide providers; these tests read the theme variables
// the real Preview wrapper carries, not the page rendered in it.
vi.mock("$app/components/Profile/Layout", () => ({ Layout: () => null }));
vi.mock("$app/components/Profile/EditPage", () => ({ EditProfile: () => null }));
// The real updateProfileSettings runs, so the save goes through its seller_profile/user split.
const request = vi.hoisted(() => vi.fn<(options: { data: Record<string, unknown> }) => Promise<Response>>());
vi.mock("$app/utils/request", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/utils/request")>()),
  request,
}));

const creatorProfile = {
  external_id: "seller-external-id",
  avatar_url: "https://example.com/avatar.png",
  name: "Seller",
  twitter_handle: null,
  subdomain: "seller.example.com",
  is_verified: false,
  can_edit: true,
  hide_follow_form: false,
};

const settings = (overrides: Partial<ProfileSettingsForm> = {}): ProfileSettingsForm => ({
  name: "Seller",
  bio: null,
  font: "ABC Favorit",
  background_color: "#ffffff",
  highlight_color: "#ff90e8",
  border_radius: "small",
  button_hover: "lift",
  profile_picture_blob_id: null,
  product_page_storefront_enabled: false,
  hide_follow_form: false,
  ...overrides,
});

// Mirrors SellerProfile::BORDER_RADIUS_CHOICES and BUTTON_HOVER_OFFSETS as ProfilePresenter sends them.
const pageProps = (profileSettings: ProfileSettingsForm) => ({
  creator_profile: creatorProfile,
  currency_code: "usd",
  sections: [],
  tabs: [],
  bio: null,
  profile_settings: profileSettings,
  editable_profile: {
    creator_profile: creatorProfile,
    currency_code: "usd",
    sections: [],
    tabs: [],
    bio: null,
    products: [],
    posts: [],
    wishlist_options: [],
  },
  profile_version: "layout-version",
  custom_html_pages_enabled: false,
  has_custom_landing_page: false,
  // A data: URL, so happy-dom loads the preview stylesheet without a network lookup.
  seller_fonts_css_source: "data:text/css,",
  theme_options: {
    border_radii: { none: "0rem", small: "0.25rem", medium: "0.5rem", large: "1rem" },
    button_hover_offsets: { lift: "0.25rem", none: "0rem" },
  },
  username: "seller",
  email_confirmation: null,
});

const renderDesignTab = (profileSettings = settings()) => {
  page.set(pageProps(profileSettings));
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en" }}>
      <SettingsPage />
    </UserAgentProvider>,
  );
  fireEvent.click(screen.getByRole("tab", { name: "Design" }));
};

const radio = (group: string, name: string) =>
  within(screen.getByRole("radiogroup", { name: group })).getByRole("radio", { name });

const checkedRadio = (group: string) =>
  [...screen.getByRole("radiogroup", { name: group }).querySelectorAll("[role=radio]")]
    .filter((element) => element.getAttribute("aria-checked") === "true")
    .map((element) => element.textContent);

const tabStops = (group: string) =>
  [...screen.getByRole("radiogroup", { name: group }).querySelectorAll<HTMLElement>("[role=radio]")]
    .filter((element) => element.tabIndex === 0)
    .map((element) => element.textContent);

const previewStyle = () => {
  const scaled = screen.getByRole("document").firstElementChild;
  if (!(scaled instanceof HTMLElement)) throw new Error("preview is not rendered");
  return scaled.style;
};

beforeEach(() => {
  // happy-dom has no stylesheet, so without this the page settles below lg and hides the preview.
  document.documentElement.style.setProperty("--breakpoint-lg", `${window.innerWidth}px`);
  canUpdate.current = true;
  page.state.reloadProps = null;
  request.mockResolvedValue(new Response(JSON.stringify({ success: true })));
});

afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

describe("Profile settings design tab", () => {
  it("selects the matching color preset when the stored colors are uppercase", () => {
    renderDesignTab(settings({ background_color: "#FFFFFF", highlight_color: "#000000" }));

    expect(checkedRadio("Color presets")).toEqual(["Black and white"]);
    expect(tabStops("Color presets")).toEqual(["Black and white"]);
  });

  it("saves a preset, corner and hover choice and keeps them selected after the reload", async () => {
    renderDesignTab();

    fireEvent.click(radio("Color presets", "Dark"));
    fireEvent.click(radio("Corners", "Large"));
    fireEvent.click(screen.getByRole("switch", { name: "Button hover effect" }));

    expect(previewStyle().getPropertyValue("--radius")).toBe("1rem");
    expect(previewStyle().getPropertyValue("--radius-sm")).toBe("1rem");
    expect(previewStyle().getPropertyValue("--button-hover-offset")).toBe("0rem");

    const saved = {
      background_color: "#000000",
      highlight_color: "#ffffff",
      border_radius: "large",
      button_hover: "none",
    };
    page.state.reloadProps = pageProps(settings(saved));
    fireEvent.click(screen.getByRole("button", { name: "Update profile" }));

    await waitFor(() => expect(request).toHaveBeenCalledOnce());
    const data = request.mock.calls[0]?.[0].data;
    expect(data?.seller_profile).toEqual(saved);
    expect(data?.user).toEqual({});

    await waitFor(() =>
      expect(screen.getByRole("button", { name: "Update profile" })).toHaveProperty("disabled", true),
    );
    expect(checkedRadio("Color presets")).toEqual(["Dark"]);
    expect(checkedRadio("Corners")).toEqual(["Large"]);
    expect(screen.getByRole("switch", { name: "Button hover effect" })).toHaveProperty("checked", false);
    expect(previewStyle().getPropertyValue("--radius")).toBe("1rem");
  });

  it("makes each group a single tab stop on its selected choice", () => {
    renderDesignTab();

    expect(tabStops("Color presets")).toEqual(["Default"]);
    expect(tabStops("Corners")).toEqual(["Small"]);
  });

  it("puts the color presets' tab stop on the first preset when the colors are custom", () => {
    renderDesignTab(settings({ background_color: "#123456", highlight_color: "#abcdef" }));

    expect(checkedRadio("Color presets")).toEqual([]);
    expect(tabStops("Color presets")).toEqual(["Default"]);
  });

  it("moves focus and selection through the corners with the arrow keys, wrapping at the ends", () => {
    renderDesignTab();
    const small = radio("Corners", "Small");
    small.focus();

    fireEvent.keyDown(small, { key: "ArrowRight" });
    expect(document.activeElement).toBe(radio("Corners", "Medium"));
    expect(checkedRadio("Corners")).toEqual(["Medium"]);

    fireEvent.keyDown(radio("Corners", "Medium"), { key: "ArrowDown" });
    fireEvent.keyDown(radio("Corners", "Large"), { key: "ArrowRight" });
    expect(document.activeElement).toBe(radio("Corners", "Square"));
    expect(checkedRadio("Corners")).toEqual(["Square"]);
    expect(tabStops("Corners")).toEqual(["Square"]);
    expect(previewStyle().getPropertyValue("--radius")).toBe("0rem");

    fireEvent.keyDown(radio("Corners", "Square"), { key: "ArrowLeft" });
    expect(document.activeElement).toBe(radio("Corners", "Large"));
    expect(checkedRadio("Corners")).toEqual(["Large"]);

    fireEvent.keyDown(radio("Corners", "Large"), { key: "ArrowUp" });
    expect(checkedRadio("Corners")).toEqual(["Medium"]);
  });

  it("applies a color preset from the keyboard, wrapping from the first to the last", () => {
    renderDesignTab();
    const defaultPreset = radio("Color presets", "Default");
    defaultPreset.focus();

    fireEvent.keyDown(defaultPreset, { key: "ArrowLeft" });

    expect(document.activeElement).toBe(radio("Color presets", "Dark"));
    expect(checkedRadio("Color presets")).toEqual(["Dark"]);
    expect(screen.getByLabelText("Background color")).toHaveProperty("value", "#000000");
    expect(screen.getByLabelText("Highlight color")).toHaveProperty("value", "#ffffff");
  });

  it("leaves the choices disabled and unchanged by arrow keys without update permission", () => {
    canUpdate.current = false;
    renderDesignTab();
    const small = radio("Corners", "Small");

    fireEvent.keyDown(small, { key: "ArrowRight" });

    expect(small).toHaveProperty("disabled", true);
    expect(checkedRadio("Corners")).toEqual(["Small"]);
    expect(checkedRadio("Color presets")).toEqual(["Default"]);
  });
});
