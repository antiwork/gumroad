import { describe, expect, it } from "vitest";

import { Taxonomy } from "$app/utils/discover";

import { buildCategoryOptions } from "$app/components/ProductEdit/ShareTab/taxonomyOptions";

const taxonomy = (key: string, label: string, parentKey: string | null = null): Taxonomy => ({
  key,
  slug: key,
  label,
  parent_key: parentKey,
});

describe("buildCategoryOptions", () => {
  it("labels each taxonomy with its full breadcrumb path", () => {
    const options = buildCategoryOptions([
      taxonomy("1", "3D"),
      taxonomy("2", "3D Assets", "1"),
      taxonomy("3", "3ds Max", "2"),
    ]);

    expect(options.find((option) => option.id === "3")?.label).toBe("3D > 3D Assets > 3ds Max");
  });

  it("sorts by full breadcrumb so each root is followed by its descendants", () => {
    // Intentionally unsorted, mimicking the popularity order taxonomies_for_nav returns.
    const options = buildCategoryOptions([
      taxonomy("10", "Fiction Books"),
      taxonomy("2", "3D Assets", "1"),
      taxonomy("1", "3D"),
      taxonomy("3", "Design"),
      taxonomy("4", "Icons", "3"),
    ]);

    expect(options.map((option) => option.label)).toEqual([
      "3D",
      "3D > 3D Assets",
      "Design",
      "Design > Icons",
      "Fiction Books",
    ]);
  });
});
