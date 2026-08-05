import { describe, expect, it } from "vitest";

// A cart save scheduled before Pay (an email keystroke's debounce, or a timer a backgrounded tab
// held through a wallet/Link popup) fires after the purchase completes and re-persists the
// pre-purchase cart — the buyer's cart comes back holding what they just bought, and they pay
// again (gumroad-private#1793: 177 unrefunded duplicate charges/week). The fix is cancelling the
// pending save before each post-purchase cart reset. Nothing in the runtime suite can see a
// regression here — the resurrect needs real timer-throttling to reproduce — so this pins the
// source: every post-purchase `cartForm.setData` that resets the items must be directly preceded
// by `debouncedSaveCartState.cancel()`.
describe("post-purchase cart save cancellation", () => {
  it("cancels the pending debounced save before each post-purchase cart reset", async () => {
    const source = (await import("$app/pages/Checkout/Show.tsx?raw")).default;

    const resets = [
      ...source.matchAll(
        /cartForm\.setData\(\(prev\) => \(\{\s*\n?\s*cart: \{\s*\n?\s*\.\.\.prev\.cart,\s*\n?\s*items: (?:failedItems|\[\])/gu,
      ),
    ];
    // The success path (items: failedItems) and the PaymentConfirmedError path (items: []).
    expect(resets.length).toBeGreaterThanOrEqual(2);

    // Requiring the reset to be the very next statement (only whitespace/comments between) is what
    // catches a conditional cancel — an `if (x) { …cancel(); }` puts a `}` right before the reset,
    // not the cancel call — and an inserted statement between the two, both of which the old
    // "somewhere in the preceding 400 chars" check let through.
    for (const match of resets) {
      const before = source
        .slice(0, match.index)
        .replace(/\/\*[\s\S]*?\*\//gu, "")
        .replace(/\/\/[^\n]*\n\s*/gu, "")
        .trimEnd();
      expect(before.endsWith("debouncedSaveCartState.cancel();")).toBe(true);
    }
  });
});
