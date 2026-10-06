// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { BlackFridayBanner } from "$app/pages/Discover/Index";

afterEach(cleanup);

describe("BlackFridayBanner", () => {
  it("renders the shared revenue total in USD", () => {
    render(
      <BlackFridayBanner stats={{ active_deals_count: 3, revenue_cents: 123_456, average_discount_percentage: 25 }} />,
    );

    expect(screen.queryByText("$1,234.56")).not.toBeNull();
  });
});
