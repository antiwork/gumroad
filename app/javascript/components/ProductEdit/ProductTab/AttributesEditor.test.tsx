// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { assertDefined } from "$app/utils/assert";

import { AttributesEditor, Attribute } from "$app/components/ProductEdit/ProductTab/AttributesEditor";

afterEach(() => {
  cleanup();
});

const renderEditor = (customAttributes: Attribute[], fileAttributes: Attribute[] = []) => {
  const setCustomAttributes = vi.fn();
  const setFileAttributes = vi.fn();
  const { container } = render(
    <AttributesEditor
      customAttributes={customAttributes}
      setCustomAttributes={setCustomAttributes}
      fileAttributes={fileAttributes}
      setFileAttributes={setFileAttributes}
      nameSuggestions={["Format", "Pages"]}
    />,
  );
  return { setCustomAttributes, setFileAttributes, container };
};

const moveUpButtons = () => screen.getAllByLabelText<HTMLButtonElement>("Move detail up");
const moveDownButtons = () => screen.getAllByLabelText<HTMLButtonElement>("Move detail down");

describe("AttributesEditor", () => {
  it("moves a detail up", () => {
    const { setCustomAttributes } = renderEditor([
      { name: "Format", value: "PDF" },
      { name: "Pages", value: "12" },
    ]);

    fireEvent.click(assertDefined(moveUpButtons()[1]));

    expect(setCustomAttributes).toHaveBeenCalledWith([
      { name: "Pages", value: "12" },
      { name: "Format", value: "PDF" },
    ]);
  });

  it("moves a detail down", () => {
    const { setCustomAttributes } = renderEditor([
      { name: "Format", value: "PDF" },
      { name: "Pages", value: "12" },
    ]);

    fireEvent.click(assertDefined(moveDownButtons()[0]));

    expect(setCustomAttributes).toHaveBeenCalledWith([
      { name: "Pages", value: "12" },
      { name: "Format", value: "PDF" },
    ]);
  });

  it("disables the move buttons at the ends of the list", () => {
    renderEditor([
      { name: "Format", value: "PDF" },
      { name: "Pages", value: "12" },
    ]);

    expect(assertDefined(moveUpButtons()[0]).disabled).toBe(true);
    expect(assertDefined(moveDownButtons()[0]).disabled).toBe(false);
    expect(assertDefined(moveUpButtons()[1]).disabled).toBe(false);
    expect(assertDefined(moveDownButtons()[1]).disabled).toBe(true);
  });

  it("leaves file-derived rows pinned and uneditable", () => {
    renderEditor([{ name: "Pages", value: "12" }], [{ name: "Format", value: "PDF" }]);

    expect(moveUpButtons()).toHaveLength(1);
    expect(moveDownButtons()).toHaveLength(1);
    expect(screen.getByDisplayValue<HTMLInputElement>("Format").disabled).toBe(true);
  });

  it("suggests names the seller has used before", () => {
    const { container } = renderEditor([{ name: "", value: "" }]);

    const datalist = assertDefined(container.querySelector("datalist"));
    expect([...container.querySelectorAll("datalist option")].map((option) => option.getAttribute("value"))).toEqual([
      "Format",
      "Pages",
    ]);
    expect(container.querySelector(`input[list="${datalist.id}"]`)).not.toBeNull();
  });
});
