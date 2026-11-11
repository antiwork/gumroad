// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { TaxonomyCategoryBreadcrumbs } from "$app/components/Discover/Layout";

afterEach(cleanup);

const taxonomies = [
  { key: "1", slug: "3d", label: "3D", parent_key: null },
  { key: "2", slug: "3d-modeling", label: "3D Modeling", parent_key: "1" },
];

describe("TaxonomyCategoryBreadcrumbs", () => {
  it("renders the taxonomy trail as the only h1, with the text of the noscript heading", () => {
    const { container } = render(
      <TaxonomyCategoryBreadcrumbs taxonomyPath="3d/3d-modeling" taxonomies={taxonomies} onClickTaxonomy={() => {}} />,
    );

    const headings = container.querySelectorAll("h1");
    expect(headings).toHaveLength(1);
    expect(headings[0]?.textContent).toBe("3D / 3D Modeling");
  });

  it("keeps every level of the trail a link, marking the last as the current page", () => {
    const { container } = render(
      <TaxonomyCategoryBreadcrumbs taxonomyPath="3d/3d-modeling" taxonomies={taxonomies} onClickTaxonomy={() => {}} />,
    );

    const links = [...container.querySelectorAll("h1 a")];
    expect(links.map((link) => link.getAttribute("href"))).toEqual(["/3d", "/3d/3d-modeling"]);
    expect(links.map((link) => link.getAttribute("aria-current"))).toEqual([null, "page"]);
  });
});
