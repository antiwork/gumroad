import { beforeEach, describe, expect, it, vi } from "vitest";

const loadStripe = vi.fn();
vi.mock("@stripe/stripe-js", () => ({ loadStripe }));
vi.mock("typia", () => ({ default: { assert: (value: unknown) => value } }));

const metaTags: Record<string, { getAttribute: (name: string) => string | null }> = {
  "meta[property='stripe:pk']": { getAttribute: () => "pk_test_123" },
  "meta[property='stripe:api_version']": { getAttribute: () => "2023-10-16" },
};

describe("getCheckoutStripeInstance", () => {
  beforeEach(() => {
    vi.resetModules();
    loadStripe.mockReset().mockResolvedValue({ id: "stripe-instance" });
    vi.stubGlobal("document", { querySelector: (selector: string) => metaTags[selector] ?? null });
  });

  it("loads Stripe scoped to the connected account when one is given", async () => {
    const { getCheckoutStripeInstance } = await import("./stripe_loader");

    await getCheckoutStripeInstance("acct_connected");

    expect(loadStripe).toHaveBeenCalledWith("pk_test_123", {
      apiVersion: "2023-10-16",
      stripeAccount: "acct_connected",
    });
  });

  it("loads the platform Stripe instance when no connected account is given", async () => {
    const { getCheckoutStripeInstance } = await import("./stripe_loader");

    await getCheckoutStripeInstance(null);

    expect(loadStripe).toHaveBeenCalledWith("pk_test_123", { apiVersion: "2023-10-16" });
  });
});
