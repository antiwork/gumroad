// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { CartItemQuantity } from "$app/components/CartItemList";

describe("CartItemQuantity", () => {
  afterEach(cleanup);

  it.each([1, 11])(
    "exposes the label once and hides the visible count from assistive tech for quantity %i",
    (quantity) => {
      const { container } = render(<CartItemQuantity>{quantity}</CartItemQuantity>);

      const srOnly = container.querySelector(".sr-only");
      const hidden = container.querySelector('[aria-hidden="true"]');
      expect(srOnly?.textContent).toBe(`Qty: ${quantity}`);
      expect(hidden?.textContent).toBe(String(quantity));
    },
  );
});
