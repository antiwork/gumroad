// @vitest-environment happy-dom
//
// Pins how the form renders the page's `errors` prop. The real redirect is covered by
// spec/requests/workflows_spec.rb.
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { type Workflow, type WorkflowFormContext } from "$app/types/workflow";
import { assertDefined } from "$app/utils/assert";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", new Proxy({}, { get: (_target, name: string) => () => `/${name}` }));
vi.mock(
  "@boxicons/react",
  () =>
    new Proxy(
      {},
      {
        has: () => true,
        get: (_target, name) => (name === "then" ? undefined : () => null),
      },
    ),
);

let flashedErrors: { base?: string | string[] } | undefined;
const form = vi.hoisted(() => ({ transform: vi.fn<(callback: () => unknown) => void>(), patch: vi.fn() }));

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
    useForm: () => ({ ...actual.useForm({}), transform: form.transform, patch: form.patch }),
  };
});

const context: WorkflowFormContext = {
  products_and_variant_options: [],
  affiliate_product_options: [],
  emailed_posts: [],
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
  form.transform.mockClear();
  form.patch.mockClear();
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

describe("WorkflowForm exclusions", () => {
  const workflow: Workflow = {
    external_id: "workflow-1",
    name: "Follow-up",
    workflow_type: "audience",
    workflow_trigger: null,
    published: false,
    first_published_at: null,
    send_to_past_customers: false,
    installments: [],
    not_bought_products: ["product-1"],
    not_bought_variants: ["variant-1"],
  };
  const options: WorkflowFormContext["products_and_variant_options"] = [
    { id: "product-1", label: "Design guide", archived: false, product_permalink: "product-1", type: "product" },
    { id: "variant-1", label: "Studio edition", archived: false, product_permalink: "product-2", type: "variant" },
    { id: "product-2", label: "Course", archived: false, product_permalink: "product-2", type: "product" },
  ];

  const exclusions = () => {
    const fieldset = screen.getByLabelText("Has not yet bought").closest("fieldset");
    if (!fieldset) throw new Error("Exclusion fieldset missing");
    return fieldset;
  };

  const selectExclusion = (fieldset: HTMLElement, label: string) => {
    // The menu mounts on focusin; its options live in a <datalist>, so they are queried by attribute.
    fireEvent.focusIn(within(fieldset).getByLabelText("Has not yet bought"));
    const option = [...fieldset.querySelectorAll('[role="option"]')].find((el) => el.textContent === label);
    if (!option) throw new Error(`${label} is not offered as an exclusion`);
    fireEvent.click(option);
  };

  it.each([{ products: ["product-1"] }, { products: [] }])(
    "retains version exclusions alongside $products",
    ({ products }) => {
      render(
        <WorkflowForm
          context={{ ...context, products_and_variant_options: options }}
          workflow={{ ...workflow, not_bought_products: products }}
        />,
      );

      expect(within(exclusions()).queryByRole("button", { name: "Studio edition" })).not.toBeNull();
      expect(within(exclusions()).queryByRole("button", { name: "Design guide" }) !== null).toBe(products.length > 0);
    },
  );

  it("adds a second exclusion alongside one that is already selected", () => {
    render(
      <WorkflowForm
        context={{ ...context, products_and_variant_options: options }}
        workflow={{ ...workflow, not_bought_variants: [] }}
      />,
    );

    const fieldset = exclusions();
    selectExclusion(fieldset, "Studio edition");

    expect(within(fieldset).getByRole("button", { name: "Design guide" })).not.toBeNull();
    expect(within(fieldset).getByRole("button", { name: "Studio edition" })).not.toBeNull();
  });

  it("saves every selected product and version", async () => {
    render(
      <WorkflowForm
        context={{ ...context, products_and_variant_options: options }}
        workflow={{ ...workflow, not_bought_products: [], not_bought_variants: [] }}
      />,
    );

    const fieldset = exclusions();
    selectExclusion(fieldset, "Design guide");
    selectExclusion(fieldset, "Course");
    selectExclusion(fieldset, "Studio edition");
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    await waitFor(() => expect(form.patch).toHaveBeenCalled());
    expect(assertDefined(form.transform.mock.lastCall)[0]()).toMatchObject({
      workflow: { not_bought_products: ["product-1", "product-2"], not_bought_variants: ["variant-1"] },
    });
  });
});
