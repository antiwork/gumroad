// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";

vi.mock("$app/data/product_tags", () => ({ getProductTags: vi.fn().mockResolvedValue([]) }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

describe("TagSelector", () => {
  afterEach(() => cleanup());

  it("shows the product tag count and length limits next to the input", () => {
    render(<TagSelector tags={[]} onChange={vi.fn()} />);

    expect(screen.getByText("Add up to 5 tags. Tags must be 2-20 characters each.")).toBeDefined();
  });
});
