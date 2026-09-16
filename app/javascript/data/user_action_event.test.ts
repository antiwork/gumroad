// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from "vitest";

import { trackUserProductAction } from "$app/data/user_action_event";

afterEach(() => vi.unstubAllGlobals());

it("keeps recovery tracking alive during navigation and includes the referrer", async () => {
  vi.stubGlobal("Routes", {
    track_user_action_link_path: (permalink: string) => `/links/${permalink}/track_user_action`,
  });
  vi.stubGlobal("window", { location: { search: "?referrer=instagram.com", pathname: "/l/fieldnotes" } });
  const fetch = vi.fn().mockResolvedValue(new Response(null, { status: 200 }));
  vi.stubGlobal("fetch", fetch);

  await trackUserProductAction({ name: "product_purchase_recovery_click", permalink: "fieldnotes", keepalive: true });

  expect(fetch).toHaveBeenCalledExactlyOnceWith(
    "/links/fieldnotes/track_user_action",
    expect.objectContaining({
      method: "POST",
      keepalive: true,
      body: JSON.stringify({
        event_name: "product_purchase_recovery_click",
        referrer: "instagram.com",
        from_multi_overlay: false,
        was_product_recommended: false,
        view_url: "/l/fieldnotes",
        is_modal: false,
      }),
    }),
  );
});
