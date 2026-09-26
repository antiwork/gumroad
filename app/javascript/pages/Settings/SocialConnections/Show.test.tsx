// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

// Imported statically for the same reason as Settings/Payments/Show.test.tsx: transforming typia
// plus the ui component tree inside a hook exceeds vitest's default hookTimeout.
import SocialConnectionsPage from "$app/pages/Settings/SocialConnections/Show";

const mocks = vi.hoisted(() => ({ usePage: vi.fn() }));

vi.mock("@inertiajs/react", () => ({
  router: { reload: vi.fn() },
  usePage: mocks.usePage,
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

// Unlike the shared Routes stub elsewhere, this one keeps the query params: the param list is
// what this file asserts on.
beforeAll(() => {
  Object.assign(globalThis, {
    Routes: new Proxy(
      {},
      {
        get:
          (_target, name: string) =>
          (params: Record<string, string | null | undefined> = {}) => {
            const path = `/${String(name).replace(/_path$|_url$/u, "")}`;
            const query = new URLSearchParams();
            for (const [key, value] of Object.entries(params)) {
              if (value != null) query.append(key, value);
            }
            const queryString = query.toString();
            return queryString ? `${path}?${queryString}` : path;
          },
      },
    ),
  });
});

afterEach(cleanup);

const renderPage = (overrides: Record<string, unknown> = {}) => {
  mocks.usePage.mockReturnValue({
    props: {
      authenticity_token: "authenticity-token",
      settings_pages: ["social_connections"],
      social_connect_return: null,
      twitter_connected: false,
      twitter_handle: null,
      twitter_write_permission_missing: false,
      youtube_connect_enabled: false,
      youtube_connected: false,
      youtube_handle: null,
      instagram_connect_enabled: false,
      instagram_connected: false,
      instagram_handle: null,
      tiktok_connect_enabled: false,
      tiktok_connected: false,
      tiktok_handle: null,
      ...overrides,
    },
  });
  render(<SocialConnectionsPage />);
};

// SocialAuthButton posts a portalled form rather than following an anchor, so the target URL
// lands on the form action.
const xConnectAction = () =>
  [...document.querySelectorAll("form")]
    .map((form) => form.getAttribute("action"))
    .find((action) => action?.includes("twitter"));

describe("SocialConnectionsPage", () => {
  it("omits x_auth_access_type from the X connect link so the granted token can post", () => {
    renderPage();

    const action = xConnectAction();

    expect(action).toBeTruthy();
    expect(action).not.toContain("x_auth_access_type");
  });

  it("keeps the X connect link pointed at the account-linking flow", () => {
    renderPage();

    expect(xConnectAction()).toContain("state=link_twitter_account");
  });

  // A read-only token still reads as connected, so without this the only way to
  // re-authorize is Disconnect first.
  it("offers Reconnect on a connected X account without requiring a disconnect", () => {
    renderPage({ twitter_connected: true, twitter_handle: "gumroad" });

    expect(screen.getByRole("button", { name: "Reconnect @gumroad from X" })).toBeTruthy();
  });

  // Disconnect stays reachable, one level in, so the row holds one line at phone width.
  it("keeps Disconnect in the connection menu", async () => {
    renderPage({ twitter_connected: true, twitter_handle: "gumroad" });

    expect(screen.queryByRole("menuitem", { name: "Disconnect @gumroad from X" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Open X connection menu" }));

    expect(await screen.findByRole("menuitem", { name: "Disconnect @gumroad from X" })).toBeTruthy();
  });

  // The token can read the profile but not post, which every other signal on the row hides.
  it("says a connected X account cannot post while its token is read-only", () => {
    renderPage({ twitter_connected: true, twitter_handle: "gumroad", twitter_write_permission_missing: true });

    expect(screen.getByText("This connection can't post launch posts. Reconnect to fix it.")).toBeTruthy();
    expect(screen.getByLabelText("Cannot post")).toBeTruthy();
    expect(screen.queryByLabelText("Connected")).toBeNull();
  });

  it("shows a writable X connection as simply connected", () => {
    renderPage({ twitter_connected: true, twitter_handle: "gumroad" });

    expect(screen.getByLabelText("Connected")).toBeTruthy();
    expect(screen.queryByText("This connection can't post launch posts. Reconnect to fix it.")).toBeNull();
  });

  // Disconnecting clears twitter_user_id, so it is confirmed rather than one click away.
  it("confirms before disconnecting", async () => {
    renderPage({ twitter_connected: true, twitter_handle: "gumroad" });

    fireEvent.click(screen.getByRole("button", { name: "Disconnect @gumroad from X" }));

    const dialog = await screen.findByRole("dialog");
    expect(dialog.textContent).toContain("Disconnect X?");
    expect(dialog.textContent).toContain("Gumroad will forget @gumroad and the access it stored.");
    expect(dialog.textContent).toContain("If you sign in with X, connect it again to keep signing in.");

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));

    expect(screen.queryByRole("dialog")).toBeNull();
  });

  it("points the Reconnect button at the same write-enabled connect flow", () => {
    renderPage({ twitter_connected: true, twitter_handle: "gumroad" });

    const action = xConnectAction();

    expect(action).toContain("state=link_twitter_account");
    expect(action).not.toContain("x_auth_access_type");
  });
});
