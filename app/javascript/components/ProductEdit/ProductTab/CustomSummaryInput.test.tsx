// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { CustomButtonTextOptionInput } from "$app/components/ProductEdit/ProductTab/CustomButtonTextOptionInput";
import { CustomSummaryInput } from "$app/components/ProductEdit/ProductTab/CustomSummaryInput";

afterEach(cleanup);

describe("CustomSummaryInput", () => {
  it("says where the summary appears and links the text to the input", () => {
    render(<CustomSummaryInput value={null} onChange={vi.fn()} />);

    expect(screen.getByLabelText("Summary")).toHaveProperty("type", "text");
    expect(screen.getByRole("textbox", { description: "Shown below the call to action on your product page." })).toBe(
      screen.getByLabelText("Summary"),
    );
  });
});

describe("CustomButtonTextOptionInput", () => {
  it("says where the call to action appears and links the text to the select", () => {
    render(
      <CustomButtonTextOptionInput value={null} onChange={vi.fn()} options={["i_want_this_prompt", "pay_prompt"]} />,
    );

    expect(screen.getByLabelText("Call to action")).toBe(
      screen.getByRole("combobox", { description: "The text on the buy button of your product page." }),
    );
  });
});
