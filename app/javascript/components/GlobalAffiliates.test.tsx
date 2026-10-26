// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { GlobalAffiliates } from "$app/components/GlobalAffiliates";

vi.mock("$app/components/DomainSettings", () => ({
  useDomains: () => ({ rootDomain: "gumroad.com", shortDomain: "gum.co" }),
  useDiscoverUrl: () => "https://gumroad.com/discover",
}));
vi.stubGlobal("SSR", false);
afterEach(cleanup);

const generate = (url: string) => {
  render(<GlobalAffiliates globalAffiliateId={42} totalSales="$0" cookieExpiryDays={7} affiliateQueryParam="a" />);
  fireEvent.change(screen.getByPlaceholderText("Paste a destination page URL"), { target: { value: url } });
  fireEvent.click(screen.getByRole("button", { name: "Generate link" }));
};

describe("affiliate link destination validation", () => {
  it.each([
    ["https://gumroad.com/l/example", "https://gumroad.com/l/example?a=42"],
    ["http://creator.gumroad.com/l/example", "http://creator.gumroad.com/l/example?a=42"],
    ["https://gum.co/example", "https://gum.co/example?a=42"],
    ["https://creator.gum.co/example", "https://creator.gum.co/example?a=42"],
    ["https://notshort.gumroad.com/l/example", "https://notshort.gumroad.com/l/example?a=42"],
    ["https://GUMROAD.COM/l/example", "https://gumroad.com/l/example?a=42"],
    [
      "https://creator.gumroad.com/l/example?offer_code=sale#details",
      "https://creator.gumroad.com/l/example?offer_code=sale&a=42#details",
    ],
    ["https://gum.co/example?a=1", "https://gum.co/example?a=42"],
  ])("accepts %s and preserves the destination", (input, expected) => {
    generate(input);
    expect(screen.getByText(expected)).toBeTruthy();
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it.each([
    "https://notgumroad.com/l/example",
    "https://notgum.co/example",
    "https://gumroad.com.example.org/l/example",
    "https://gumroad.com@example.org/l/example",
    "https://example.org/l/example",
    "ftp://gumroad.com/l/example",
    "ftp://creator.gumroad.com/l/example",
    "wss://gum.co/example",
    "gumroad.com/l/example",
    "",
  ])("rejects %s without generating an affiliate link", (input) => {
    generate(input);
    expect(screen.getByRole("alert").textContent).toContain("Invalid URL. Make sure your URL is a Gumroad URL");
    expect(screen.getByText("Your affiliate link").closest("fieldset")?.textContent).not.toContain("a=42");
  });
});
