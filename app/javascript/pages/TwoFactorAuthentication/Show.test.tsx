// @vitest-environment happy-dom
import { act, cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import TwoFactorAuthenticationPage from "$app/pages/TwoFactorAuthentication/Show";

const SLOW_NOTICE = /taking longer than usual/iu;

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

// `processing` is the flag the page hands the notice; the code field and the resend / switch-method
// forms each own one, and a stalled visit can belong to either.
const switchForm = vi.hoisted(() => ({ processing: false }));

vi.mock("@inertiajs/react", () => ({
  router: { post: () => undefined },
  useForm: () => ({ data: {}, setData: () => undefined, post: () => undefined, processing: switchForm.processing }),
  usePage: () => ({
    props: {
      user_id: "1",
      email: "seller@example.com",
      token: null,
      authenticity_token: "test-csrf",
      two_factor_method: "email",
      token_sent_at: null,
      resend_cooldown_seconds: 0,
    },
  }),
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
}));

vi.mock("$app/components/Authentication/Layout", () => ({
  Layout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));
vi.mock("$app/components/AuthAlert", () => ({ AuthAlert: () => null }));
vi.mock("$app/components/useOriginalLocation", () => ({
  useOriginalLocation: () => "http://localhost:3000/two_factor_authentication",
}));

const advance = (ms: number) =>
  act(() => {
    vi.advanceTimersByTime(ms);
  });

afterEach(cleanup);
beforeEach(() => {
  switchForm.processing = false;
  vi.useFakeTimers();
});
afterEach(() => vi.useRealTimers());

describe("two-factor page on a slow connection", () => {
  it("surfaces the notice while a resend or switch-method visit is stalled", () => {
    switchForm.processing = true;
    render(<TwoFactorAuthenticationPage />);

    advance(15_000);

    expect(screen.getByRole("alert").textContent).toMatch(SLOW_NOTICE);
  });

  it("stays quiet while no visit is in flight", () => {
    render(<TwoFactorAuthenticationPage />);

    advance(60_000);

    expect(screen.queryByRole("alert")).toBeNull();
  });
});
