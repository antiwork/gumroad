import { describe, expect, it } from "vitest";

// loadSurcharges only forwards `item.uid`. The production value is computed in
// Show.tsx getProducts via getCartItemUid. Planting uid on a reducer fixture
// stays green if that mapping is deleted, so this pins the constructor itself.
describe("checkout cart-item uid mapping", () => {
  it("computes payment-product uid from the cart item in getProducts", async () => {
    const source = (await import("$app/pages/Checkout/Show.tsx?raw")).default;

    const getProducts = source.match(
      /function getProducts\(state: CartState\): Product\[] \{[\s\S]*?return \{[\s\S]*?uid: getCartItemUid\(item\),/u,
    );
    expect(getProducts).not.toBeNull();

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
