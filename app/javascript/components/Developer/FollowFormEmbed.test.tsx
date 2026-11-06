// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { FollowFormEmbed } from "$app/components/Developer/FollowFormEmbed";
import { DomainSettingsProvider } from "$app/components/DomainSettings";

const mocks = vi.hoisted(() => ({ request: vi.fn(), showAlert: vi.fn() }));
vi.mock("$app/utils/request", async (importOriginal) => ({
  ...(await importOriginal<typeof import("$app/utils/request")>()),
  request: mocks.request,
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: mocks.showAlert }));

beforeEach(() => {
  mocks.request.mockReset();
  mocks.showAlert.mockReset();
  Object.assign(globalThis, {
    Routes: {
      follow_user_from_embed_form_path: () => "/follow_from_embed_form",
      follow_user_from_embed_form_url: () => "https://gumroad.test/follow_from_embed_form",
    },
  });
});
afterEach(cleanup);

describe("FollowFormEmbed preview", () => {
  it.each([
    [
      "the server's reason for refusing the follow",
      JSON.stringify({ success: false, message: "Please join the waitlist from the product page." }),
      "Please join the waitlist from the product page.",
    ],
    ["a generic error when the server gives no reason", JSON.stringify({ success: false }), null],
    ["a generic error when the response is not JSON", "<html>Not found</html>", null],
  ])("shows %s", async (_, body, message) => {
    mocks.request.mockResolvedValue(new Response(body, { status: 422 }));
    render(
      <DomainSettingsProvider
        value={{
          scheme: "https",
          appDomain: "gumroad.test",
          rootDomain: "gumroad.test",
          shortDomain: "gum.test",
          discoverDomain: "gumroad.test",
          thirdPartyAnalyticsDomain: "gumroad.test",
          apiDomain: "api.gumroad.test",
        }}
      >
        <FollowFormEmbed sellerId="seller" productId="product" preview />
      </DomainSettingsProvider>,
    );

    fireEvent.change(screen.getByPlaceholderText("Your email address"), { target: { value: "visitor@example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "Follow" }));

    await waitFor(() =>
      expect(mocks.showAlert).toHaveBeenCalledWith(
        message ?? "Sorry, something went wrong. Please try again.",
        "error",
      ),
    );
  });
});
