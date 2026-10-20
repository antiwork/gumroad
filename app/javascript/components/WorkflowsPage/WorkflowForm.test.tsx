// @vitest-environment happy-dom
//
// A failed save is answered with `redirect_to ..., inertia: { errors: { base: [...] } }`, so the
// message arrives as a *page prop* on the re-rendered form — not as a 422 JSON body. `useForm`
// only fills `form.errors` from a 422, so reading it there renders nothing and the form silently
// re-enables (the bug these tests pin). The form must read the flashed page prop.
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { type WorkflowFormContext } from "$app/types/workflow";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", new Proxy({}, { get: (_target, name: string) => () => `/${name}` }));

let flashedErrors: { base?: string | string[] } | undefined;

vi.mock("@inertiajs/react", async () => {
  const actual = await vi.importActual<typeof import("@inertiajs/react")>("@inertiajs/react");
  return {
    ...actual,
    usePage: () => ({
      props: { errors: flashedErrors },
      url: "/workflows/new",
      component: "Workflows/New",
      version: null,
    }),
  };
});

const context: WorkflowFormContext = {
  products_and_variant_options: [],
  affiliate_product_options: [],
  timezone: "UTC",
  currency_symbol: "$",
  countries: ["United States"],
  aws_access_key_id: "aws-key",
  s3_url: "https://s3.example.com",
  user_id: "user-id",
  gumroad_address: "123 Example St",
  email_from: "seller@example.com",
  eligible_for_abandoned_cart_workflows: true,
};

const MESSAGE = "Name can't be blank";

beforeEach(() => {
  flashedErrors = undefined;
});
afterEach(cleanup);

describe("WorkflowForm base error", () => {
  it("renders the base error flashed by a failed create/publish redirect", () => {
    flashedErrors = { base: [MESSAGE] };
    render(<WorkflowForm context={context} />);

    expect(screen.queryByText(MESSAGE)).not.toBeNull();
  });

  it("renders nothing when no error was flashed", () => {
    render(<WorkflowForm context={context} />);

    expect(screen.queryByText(MESSAGE)).toBeNull();
  });

  it("renders a bare-string base error in full rather than its first character", () => {
    flashedErrors = { base: MESSAGE };
    render(<WorkflowForm context={context} />);

    expect(screen.queryByText(MESSAGE)).not.toBeNull();
    expect(screen.queryByText("N")).toBeNull();
  });
});
