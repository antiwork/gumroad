// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import PiracyReportsShow from "$app/pages/PiracyReports/Show";

import { UserAgentProvider } from "$app/components/UserAgent";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

const mocks = vi.hoisted(() => ({ usePage: vi.fn() }));

vi.mock("@inertiajs/react", () => ({
  usePage: mocks.usePage,
  useForm: () => ({ data: { signed_by_name: "", confirmations: [] }, errors: {}, processing: false, setData: vi.fn() }),
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));

const FIRST_DAY = "2026-10-21";
const LAST_DAY = "2026-10-27";

const renderAlert = (now: string) => {
  vi.setSystemTime(new Date(now));
  mocks.usePage.mockReturnValue({
    props: {
      report: {
        id: "report-1",
        state: "counter_noticed",
        url: "https://pirate.example/course",
        created_at: "2026-10-01T00:00:00Z",
        notice_text: null,
        notice_digest: null,
        signed_at: null,
        sent_at: null,
        recipient_name: null,
        counter_notice_received_on: "2026-10-07",
        restoration_window: [FIRST_DAY, LAST_DAY],
        waiting_on_person: false,
        outcome: null,
        signed_by_name: null,
        history: [],
      },
      product: { name: "Course", url: "https://seller.example/l/course" },
      confirmations: [],
      confirmations_version: "v1",
    },
  });
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <PiracyReportsShow />
    </UserAgentProvider>,
  );
  return screen.getByRole("status").textContent;
};

afterEach(cleanup);
// Only Date is faked: React and the test renderer still need real timers.
beforeEach(() => vi.useFakeTimers({ toFake: ["Date"] }));
afterEach(() => vi.useRealTimers());

describe("piracy report page after a counter-notice", () => {
  it("names the first date as the court-action deadline just before it", () => {
    const text = renderAlert("2026-10-20T23:59:59Z");

    expect(text).toContain("file a court action");
    expect(text).toContain("before October 21, 2026");
    expect(text).toContain("between about October 21, 2026 and October 27, 2026");
    expect(text).not.toContain("Since about");
  });

  it("switches to the passed-deadline message at the first date", () => {
    const text = renderAlert("2026-10-21T00:00:00Z");

    expect(text).toContain("Since about October 21, 2026, the site can put the page back");
    expect(text).not.toContain("To stop that");
  });

  it("keeps naming the first date between the two dates", () => {
    const text = renderAlert("2026-10-24T12:00:00Z");

    expect(text).toContain("Since about October 21, 2026, the site can put the page back");
    expect(text).not.toContain("October 27, 2026");
    expect(text).not.toContain("To stop that");
  });
});
