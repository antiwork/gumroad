// @vitest-environment happy-dom
import { cleanup, render } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import Api from "$app/pages/Public/Api";

vi.mock("$app/components/Developer/Layout", () => ({
  Layout: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

afterEach(cleanup);

describe("public API documentation", () => {
  it("mounts workflow write endpoints after the read endpoints", () => {
    render(<Api />);

    const workflows = document.getElementById("workflows");
    if (!workflows) throw new Error("Could not find the Workflows API resource");

    expect(
      Array.from(workflows.children)
        .map((child) => child.id)
        .filter(Boolean),
    ).toEqual([
      "get-/workflows",
      "get-/workflows/:id",
      "post-/workflows/:workflow_id/emails",
      "put-/workflows/:workflow_id/emails/:email_id",
    ]);
  });
});
