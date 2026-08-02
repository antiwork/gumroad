// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";

vi.mock("$app/data/product_tags", () => ({ getProductTags: vi.fn().mockResolvedValue([]) }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const typeTag = (tag: string) => {
  const input = screen.getByRole("combobox");
  fireEvent.change(input, { target: { value: tag } });
  fireEvent.keyDown(input, { key: "," });
};

const tags = (count: number) => Array.from({ length: count }, (_, index) => `tag${index}`);

describe("TagSelector", () => {
  afterEach(() => cleanup());

  it("shows the product tag count and length limits next to the input", () => {
    render(<TagSelector tags={[]} onChange={vi.fn()} />);

    expect(screen.getByText("The editor supports up to 10 tags. Tags must be 2-20 characters each.")).toBeDefined();
  });

  it("accepts a tenth tag", () => {
    const onChange = vi.fn();
    render(<TagSelector tags={tags(9)} onChange={onChange} />);

    typeTag("tenth");

    expect(onChange).toHaveBeenCalledWith([...tags(9), "tenth"]);
  });

  it("refuses an eleventh tag", () => {
    const onChange = vi.fn();
    render(<TagSelector tags={tags(10)} onChange={onChange} />);

    typeTag("eleventh");

    expect(onChange).not.toHaveBeenCalled();
  });
});
