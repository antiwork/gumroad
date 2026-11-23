// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, expect, it, vi } from "vitest";

import { fetchAccountInfo, fetchCalendarList, getOAuthUrl } from "$app/data/google_calendar_integration";
import { startOauthRedirectChecker } from "$app/utils/oauth";

import { GoogleCalendarIntegrationEditor } from "$app/components/ProductEdit/ProductTab/GoogleCalendarIntegrationEditor";

vi.mock("$app/data/google_calendar_integration", () => ({
  fetchAccountInfo: vi.fn(),
  fetchCalendarList: vi.fn(),
  getOAuthUrl: vi.fn(),
}));
vi.mock("$app/utils/oauth", () => ({ startOauthRedirectChecker: vi.fn() }));
vi.mock("$app/components/ProductEdit/state", () => ({
  useProductEditContext: () => ({ googleClientId: "test-client", updateProduct: vi.fn() }),
}));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
  vi.resetAllMocks();
});

it("keeps Google Calendar disconnected when an authorization finishes after the seller turns the switch off", async () => {
  vi.spyOn(window, "open").mockReturnValue(null);
  vi.mocked(getOAuthUrl).mockReturnValue("https://example.com/calendar/auth");
  vi.mocked(fetchCalendarList).mockResolvedValue([{ id: "calendar", summary: "Calendar" }]);
  let completeAccountLookup!: (account: Awaited<ReturnType<typeof fetchAccountInfo>>) => void;
  vi.mocked(fetchAccountInfo).mockImplementationOnce(
    () =>
      new Promise((resolve) => {
        completeAccountLookup = resolve;
      }),
  );
  const onChange = vi.fn();
  render(<GoogleCalendarIntegrationEditor integration={null} onChange={onChange} />);
  const toggle = screen.getByRole("switch", { name: "Connect with Google Calendar to sync your calls" });
  fireEvent.click(toggle);
  const attempt = vi.mocked(startOauthRedirectChecker).mock.calls[0]?.[0];
  if (!attempt) throw new Error("Calendar authorization did not start");
  const finish = attempt.onSuccess("example-code");
  fireEvent.click(toggle);
  await act(async () => {
    completeAccountLookup({
      accessToken: "example-access",
      refreshToken: "example-refresh",
      email: "seller@example.com",
    });
    await finish;
  });
  expect(onChange).toHaveBeenCalledExactlyOnceWith(null);
});
