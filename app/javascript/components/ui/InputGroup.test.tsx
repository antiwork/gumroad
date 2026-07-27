// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";

afterEach(cleanup);

const groupOf = (input: HTMLElement) => {
  const group = input.closest("div");
  if (!group) throw new Error("expected the input to be wrapped in a group element");
  return group;
};

describe("InputGroup", () => {
  it("keeps a disabled group's contents at full opacity", () => {
    render(
      <InputGroup disabled>
        <Input aria-label="Amount" value="3" readOnly />
      </InputGroup>,
    );

    const group = groupOf(screen.getByLabelText("Amount"));
    // CSS `opacity` applies to the whole subtree, so fading the group hides any value it is
    // showing. The state is signalled with a background tint and the cursor instead.
    expect(group.className).not.toMatch(/\bopacity-(?!100\b)/u);
    expect(group.className).toContain("bg-active-bg");
    expect(group.className).toContain("cursor-not-allowed");
  });

  // A translucent background tint is exactly what forced-colours modes (Windows High Contrast)
  // throw away, which would leave a disabled group looking identical to an editable one. WCAG
  // 1.4.1 wants the state carried by something other than colour, so the border goes dashed.
  it("marks a disabled group with a non-colour cue under forced colours", () => {
    render(
      <InputGroup disabled>
        <Input aria-label="Amount" value="3" readOnly />
      </InputGroup>,
    );

    expect(groupOf(screen.getByLabelText("Amount")).className).toContain("forced-colors:border-dashed");
  });

  it("does not mark an enabled group as disabled", () => {
    render(
      <InputGroup>
        <Input aria-label="Amount" value="3" readOnly />
      </InputGroup>,
    );

    const { className } = groupOf(screen.getByLabelText("Amount"));
    expect(className).not.toContain("cursor-not-allowed");
    expect(className).not.toContain("forced-colors:border-dashed");
  });
});
