// @vitest-environment happy-dom
import { cleanup, fireEvent, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  VARIANT_DESCRIPTION_MAX_LENGTH,
  VariantDescriptionInput,
} from "$app/components/ProductEdit/ProductTab/VariantDescriptionInput";

afterEach(cleanup);

describe("VariantDescriptionInput", () => {
  it("caps the value at the column's length and shows how much room is left", () => {
    const view = render(<VariantDescriptionInput id="version-description" value="abc" onChange={vi.fn()} />);

    const description = view.getByRole("textbox", { name: "Description", description: "3/255 characters" });
    expect(description).toHaveProperty("maxLength", VARIANT_DESCRIPTION_MAX_LENGTH);
  });

  it("counts what the seller types", () => {
    const onChange = vi.fn();
    const view = render(<VariantDescriptionInput id="version-description" value="" onChange={onChange} />);

    const description = view.getByRole("textbox", { name: "Description", description: "0/255 characters" });
    fireEvent.change(description, { target: { value: "hello" } });

    expect(onChange).toHaveBeenLastCalledWith("hello");
  });
});
