import { describe, expect, it } from "vitest";

import { sanitizedPageLocation } from "./google_analytics";

describe("sanitizedPageLocation", () => {
  it("strips reset_password_token so it never reaches analytics (gumroad-private#1260)", () => {
    expect(sanitizedPageLocation("https://gumroad.com/users/password/edit?reset_password_token=abc123SECRET")).toBe(
      "https://gumroad.com/users/password/edit",
    );
  });

  it("strips other single-use secret tokens while keeping harmless params", () => {
    expect(
      sanitizedPageLocation(
        "https://gumroad.com/some/page?confirmation_token=s1&invitation_token=s2&unlock_token=s3&utm_source=email",
      ),
    ).toBe("https://gumroad.com/some/page?utm_source=email");
  });

  it("leaves URLs without sensitive params unchanged", () => {
    expect(sanitizedPageLocation("https://gumroad.com/l/demo?wanted=true")).toBe(
      "https://gumroad.com/l/demo?wanted=true",
    );
  });

  it("returns an empty string for unparseable URLs rather than forwarding them", () => {
    expect(sanitizedPageLocation("not a url")).toBe("");
  });
});
