import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { updateProfileSettings } from "$app/data/profile_settings";

const request = vi.hoisted(() => vi.fn<(options: { data: Record<string, unknown> }) => Promise<Response>>());
vi.mock("$app/utils/request", () => ({ request, ResponseError: class extends Error {} }));
vi.stubGlobal("Routes", { profile_path: () => "/profile" });

const sentData = () => {
  const call = request.mock.calls[0];
  if (!call) throw new Error("request was not called");
  return call[0].data;
};

describe("updateProfileSettings", () => {
  beforeEach(() => {
    request.mockResolvedValue(new Response(JSON.stringify({ success: true })));
  });

  afterEach(() => {
    vi.resetAllMocks();
  });

  it("sends the theme fields under seller_profile and everything else under user", async () => {
    await updateProfileSettings({
      name: "New name",
      background_color: "#000000",
      border_radius: "none",
      button_hover: "none",
    });

    expect(sentData()).toMatchObject({
      user: { name: "New name" },
      seller_profile: { background_color: "#000000", border_radius: "none", button_hover: "none" },
    });
    expect(sentData().user).not.toHaveProperty("border_radius");
    expect(sentData().user).not.toHaveProperty("button_hover");
  });

  it("leaves seller_profile out when no theme field changed", async () => {
    await updateProfileSettings({ name: "New name" });

    expect(sentData()).not.toHaveProperty("seller_profile");
  });
});
