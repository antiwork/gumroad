// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
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

const renderPage = () => {
  mocks.usePage.mockReturnValue({
    props: {
      authenticity_token: "authenticity-token",
      settings_pages: ["social_connections"],
      social_connect_return: null,
      twitter_connected: false,
      twitter_handle: null,
      youtube_connect_enabled: false,
      youtube_connected: false,
      youtube_handle: null,
      instagram_connect_enabled: false,
      instagram_connected: false,
      instagram_handle: null,
      tiktok_connect_enabled: false,
      tiktok_connected: false,
      tiktok_handle: null,
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
});
