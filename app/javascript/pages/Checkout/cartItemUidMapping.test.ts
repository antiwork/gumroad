import { describe, expect, it } from "vitest";

// loadSurcharges only forwards `item.uid`. The production value is computed in
// Show.tsx getProducts via getCartItemUid. Planting uid on a reducer fixture
// stays green if that mapping is deleted, so this pins the constructor itself.
const sliceFunction = (source: string, signature: string): string | null => {
  const start = source.indexOf(signature);
  if (start < 0) return null;
  const open = source.indexOf("{", start);
  if (open < 0) return null;
  let depth = 0;
  for (let i = open; i < source.length; i++) {
    const ch = source[i];
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(start, i + 1);
    }
  }
  return null;
};

describe("checkout cart-item uid mapping", () => {
  it("computes payment-product uid from the cart item in getProducts", async () => {
    const source = (await import("$app/pages/Checkout/Show.tsx?raw")).default;

    const getProducts = sliceFunction(source, "function getProducts(state: CartState): Product[] {");
    expect(getProducts).not.toBeNull();
    expect(getProducts).toMatch(/uid: getCartItemUid\(item\),/);
    // The order-line mapper is a later sibling; leaking into it would make this
    // pin stay green after the getProducts uid mapping is deleted.
    expect(getProducts).not.toMatch(/linePricing\.map/);

    const orderLine = source.match(
      /return linePricing\.map\(\(\{ item, discounted, discountedPriceToChargeNow \}, index\) => \{[\s\S]*?uid: getCartItemUid\(item\),/u,
    );
    expect(orderLine).not.toBeNull();
  });

  it("derives uid from permalink and option, including a blank option", async () => {
    const source = (await import("$app/pages/Checkout/Show.tsx?raw")).default;
    expect(source).toMatch(
      /function getCartItemUid\(item: CartItem\) \{\s*return `\$\{item\.product\.permalink\} \$\{item\.option_id \?\? ""\}`;/u,
    );
  });
});
