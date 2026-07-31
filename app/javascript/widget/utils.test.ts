import { describe, it, expect, beforeAll } from "vitest";

import { isValidHost } from "$app/widget/utils";

// isValidHost is the widget's entire trust boundary: both postMessage handlers (widget/embed.ts
// L49, widget/overlay.ts L98) drop any message whose origin it rejects, and parseProductURL
// refuses to load a product from a host it rejects. So these cases are the security contract,
// not incidental coverage — a regression here lets an attacker-registered host talk to the widget.
//
// The domains are set here rather than read from the ambient env: isValidHost runs
// typia.assert<string> on ROOT_DOMAIN, so an unset value throws instead of returning false, and
// the vitest process does not inherit the app's env.
const ROOT_DOMAIN = "gumroad.com";
const SHORT_DOMAIN = "gum.co";

beforeAll(() => {
  process.env.ROOT_DOMAIN = ROOT_DOMAIN;
  process.env.SHORT_DOMAIN = SHORT_DOMAIN;
});

const valid = (host: string, customDomain?: string) => isValidHost(new URL(`https://${host}/l/x`), customDomain);

describe("isValidHost", () => {
  it("accepts the root domain and its subdomains", () => {
    expect(valid(ROOT_DOMAIN)).toBe(true);
    expect(valid(`app.${ROOT_DOMAIN}`)).toBe(true);
    expect(valid(`deep.nested.${ROOT_DOMAIN}`)).toBe(true);
  });

  it("accepts the short domain exactly", () => {
    expect(valid(SHORT_DOMAIN)).toBe(true);
  });

  // The regression this file exists for. `host.endsWith(ROOT_DOMAIN)` accepted every one of
  // these, and each is a domain an attacker can simply register.
  it("rejects a host that merely ends with the root domain as a string", () => {
    expect(valid(`not${ROOT_DOMAIN}`)).toBe(false);
    expect(valid(`evil-${ROOT_DOMAIN}`)).toBe(false);
    expect(valid(`attacker${ROOT_DOMAIN}`)).toBe(false);
  });

  it("rejects the root domain used as a prefix of another domain", () => {
    expect(valid(`${ROOT_DOMAIN}.evil.example`)).toBe(false);
  });

  it("rejects an unrelated host", () => {
    expect(valid("example.com")).toBe(false);
  });

  describe("with a seller custom domain", () => {
    const custom = "shop.example.com";

    it("accepts the custom domain and its subdomains", () => {
      expect(valid(custom, custom)).toBe(true);
      expect(valid(`www.${custom}`, custom)).toBe(true);
    });

    // Same suffix bug on the seller-supplied half. Worse here than for the root domain: the
    // attacker only has to register a name ending in the seller's, not in ours.
    it("rejects a host that merely ends with the custom domain as a string", () => {
      expect(valid(`evil${custom}`, custom)).toBe(false);
      expect(valid(`evil-${custom}`, custom)).toBe(false);
    });

    it("still rejects an unrelated host", () => {
      expect(valid("example.org", custom)).toBe(false);
    });
  });

  // Guards the `customDomain !== undefined` form: the old `customDomain && ...` returned the
  // empty string rather than a boolean when no custom domain was set, so a caller reading the
  // result as a value (not just via `!`) saw a falsy non-boolean.
  it("returns a boolean when no custom domain is supplied", () => {
    expect(valid("example.com")).toBe(false);
    expect(valid("example.com", "")).toBe(false);
  });

  // An empty customDomain is reachable in production: it is `new URL(script.src).host`, which is
  // "" for a host-less scheme such as a seller page saved to `file:`. Without an explicit empty
  // check the comparison degenerates to `host.endsWith(".")`, which is true for any host written
  // in fully-qualified trailing-dot form — and browsers treat `https://evil.example./` as a real
  // origin whose `url.host` is `"evil.example."`. So this is the same hole in a corner, and the
  // plain `valid("example.com", "")` case above cannot see it: that host has no trailing dot.
  it("rejects a trailing-dot FQDN when the custom domain is empty", () => {
    expect(valid("evil.example.", "")).toBe(false);
    expect(valid("evil.example.")).toBe(false);
  });

  // `URL` keeps the DNS root dot in `url.host`, so `https://gumroad.com./l/x` arrives here as
  // `gumroad.com.` — the same name, a different string. Comparing literally rejected our own
  // fully-qualified origins: the widget refused those product links and dropped their messages.
  describe("fully qualified trailing-dot hosts", () => {
    it("accepts our own domains written with the root dot", () => {
      expect(valid(`${ROOT_DOMAIN}.`)).toBe(true);
      expect(valid(`seller.${ROOT_DOMAIN}.`)).toBe(true);
      expect(valid(`${SHORT_DOMAIN}.`)).toBe(true);
    });

    it("accepts a seller custom domain written with the root dot", () => {
      const custom = "shop.example.com";
      expect(valid(`${custom}.`, custom)).toBe(true);
      expect(valid(`www.${custom}.`, custom)).toBe(true);
    });

    // Normalizing the dot must not widen the boundary: an attacker-registrable host stays out
    // whether it is written fully qualified or not.
    it("still rejects attacker-registrable hosts written with the root dot", () => {
      expect(valid(`evil-${ROOT_DOMAIN}.`)).toBe(false);
      expect(valid(`not${ROOT_DOMAIN}.`)).toBe(false);
      expect(valid(`${ROOT_DOMAIN}.evil.example.`)).toBe(false);
      expect(valid(`evil${SHORT_DOMAIN}.`)).toBe(false);
      expect(valid("evilshop.example.com.", "shop.example.com")).toBe(false);
    });

    // Only ONE terminal dot is stripped, so a doubled dot is not a way back to the empty-domain
    // hole the plain empty check closes.
    it("rejects a doubled root dot", () => {
      expect(valid(`${ROOT_DOMAIN}..`)).toBe(false);
    });
  });
});
