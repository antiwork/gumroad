// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { AnalyticsCountriesTable } from "$app/components/Analytics/LocationsTable";
import { type AnalyticsDataByState } from "$app/data/analytics";

afterEach(cleanup);

const usStateBreakdown = [0, 0, 0];

// Shape returned by GET /analytics/data/by_state: every product has an entry in all three maps
// (United States pre-seeded), but only `views` carries a country with traffic and no purchase.
const locationData: AnalyticsDataByState = {
  by_state: {
    views: { productPermalink: { "United States": usStateBreakdown, Canada: 288, India: 17 } },
    sales: { productPermalink: { "United States": usStateBreakdown, India: 1 } },
    totals: { productPermalink: { "United States": usStateBreakdown, India: 2_500, France: 0 } },
  },
};

const renderTable = (selectedProducts = ["productPermalink"]) =>
  render(
    <AnalyticsCountriesTable
      locationData={locationData}
      selectedProducts={selectedProducts}
      locations={{ canada: "CA", india: "IN", france: "FR" }}
      caption="Locations"
    />,
  );

// Each cell repeats its column label for the mobile layout, so a value reads as "Views288".
const rows = () =>
  [...document.querySelectorAll("tbody tr")].map((row) =>
    [...row.querySelectorAll("td")].map((cell) => cell.textContent?.trim() ?? ""),
  );

const rowFor = (country: string) => rows().find((row) => row[0]?.includes(country));

describe("AnalyticsCountriesTable", () => {
  it("lists a country that has page views but no sales", () => {
    renderTable();

    expect(rowFor("Canada")).toEqual([expect.stringContaining("Canada"), "Views288", "Sales0", "Total$0"]);
  });

  it("keeps countries that have sales, and skips countries present only as zeros", () => {
    renderTable();

    expect(rowFor("India")).toEqual([expect.stringContaining("India"), "Views17", "Sales1", "Total$25"]);
    expect(rowFor("France")).toBeUndefined();
  });

  it("ignores countries of products that are not selected", () => {
    renderTable([]);

    expect(rows()).toEqual([["CountryNothing yet"]]);
  });
});
