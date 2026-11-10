// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { SocialAuth } from "$app/components/Authentication/SocialAuth";

vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

const page = vi.hoisted(() => ({ isMobileApp: false, location: "https://gumroad.com/login" }));

vi.mock("@inertiajs/react", () => ({
  usePage: () => ({ props: { is_gumroad_mobile_app: page.isMobileApp, authenticity_token: "test-csrf" } }),
}));
vi.mock("$app/components/useOriginalLocation", () => ({ useOriginalLocation: () => page.location }));
vi.mock("$app/components/FeatureFlags", () => ({ useFeatureFlags: () => ({ disable_stripe_signup: false }) }));

const renderAt = (location: string, isMobileApp = false) => {
  page.location = location;
  page.isMobileApp = isMobileApp;
  render(<SocialAuth />);
  return screen.queryByRole("button", { name: "Apple" });
};

afterEach(cleanup);

describe("Apple sign-in button", () => {
  it("shows on the web login page", () => {
    expect(renderAt("https://gumroad.com/login")).not.toBeNull();
  });

  it("shows on the web forgot-password page", () => {
    expect(renderAt("https://gumroad.com/forgot_password")).not.toBeNull();
  });

  it.each(["/signup", "/signup/", "/signup.html", "/signup?next=%2Flibrary"])(
    "stays off the web signup page at %s",
    (path) => {
      expect(renderAt(`https://gumroad.com${path}`)).toBeNull();
    },
  );

  it("shows on signup inside the mobile app", () => {
    expect(renderAt("https://gumroad.com/signup", true)).not.toBeNull();
  });
});
