import { describe, expect, it } from "vitest";

describe("product page bundle mobile layout", () => {
  it("stacks the price/seller row on mobile and floors bundle CartItem columns", async () => {
    const source = (await import("$app/components/Product/index.tsx?raw")).default;

    expect(source).toContain(
      'className="grid grid-cols-1 gap-[1px] border-t border-border p-0 sm:grid-cols-[auto_auto_minmax(max-content,1fr)]"',
    );
    expect(source).not.toContain("grid-cols-[auto_1fr]");
    expect(source).toContain('CartItemMedia className="h-16 w-16 shrink-0 sm:h-28 sm:w-28"');
    expect(source).toContain('CartItemMain className="min-h-16 min-w-2/5 sm:h-28"');
    expect(source).toContain('CartItemEnd className="max-w-1/2 flex-row items-start gap-4 p-4 text-right"');
  });
});
