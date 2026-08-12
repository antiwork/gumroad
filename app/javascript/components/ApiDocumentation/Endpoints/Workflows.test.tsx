// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it } from "vitest";

import { CreateWorkflowEmail, UpdateWorkflowEmail } from "$app/components/ApiDocumentation/Endpoints/Workflows";

afterEach(cleanup);

const snippetText = (caption: string) => {
  const figure = screen.getByText(caption).closest("figure");
  const code = figure?.querySelector("code");
  if (!code) throw new Error(`Could not find the ${caption} code snippet`);

  return code.textContent ?? "";
};

const EMAIL_RESPONSE_KEYS = [
  "id",
  "subject",
  "message",
  "audience_type",
  "product_id",
  "state",
  "published_at",
  "send_emails",
  "delay",
  "sent_count",
  "open_count",
  "open_rate",
  "click_count",
  "click_rate",
  "created_at",
  "updated_at",
];

const expectResponseContract = (responseText: string) => {
  const response = JSON.parse(responseText);

  expect(Object.keys(response)).toEqual(["success", "email"]);
  expect(response.success).toBe(true);
  expect(Object.keys(response.email)).toEqual(EMAIL_RESPONSE_KEYS);
  expect(response.email).toMatchObject({
    open_count: null,
    open_rate: null,
    click_count: null,
    click_rate: null,
  });
};

const expectWriteAnalyticsFields = (container: HTMLElement) => {
  const fields = new Map(
    Array.from(container.querySelectorAll("strong")).map((field) => [
      field.textContent,
      field.parentElement?.textContent,
    ]),
  );

  expect(fields.get("open_count")).toBe(
    "open_count (number | null) — Number of unique opens for this step; null because write responses do not compute analytics",
  );
  expect(fields.get("open_rate")).toBe(
    "open_rate (number | null) — Unique open rate; null because write responses do not compute analytics",
  );
  expect(fields.get("click_count")).toBe(
    "click_count (number | null) — Number of unique clicks for this step; null because write responses do not compute analytics",
  );
  expect(fields.get("click_rate")).toBe(
    "click_rate (number | null) — Unique click rate; null because write responses do not compute analytics",
  );
};

describe("workflow email API documentation", () => {
  it("renders the create contract with an executable multiline cURL example", () => {
    const { container } = render(<CreateWorkflowEmail />);

    expect(screen.getByRole("heading", { name: "POST /workflows/:workflow_id/emails" })).toBeTruthy();
    expect(container.textContent).toContain("subject Non-empty email subject line");
    expect(container.textContent).toContain("body HTML email body");
    expect(container.textContent).toContain("delay_amount Non-negative integer delay");
    expect(container.textContent).toContain('delay_unit One of "hour", "day", "week", or "month"');

    expect(snippetText("cURL example")).toBe(
      [
        "curl https://api.gumroad.com/v2/workflows/0ssD7B0cF6B5XQd3J7lY2A==/emails \\",
        '  -d "access_token=ACCESS_TOKEN" \\',
        '  -d "subject=Week four" \\',
        '  -d "body=<p>Keep going.</p>" \\',
        '  -d "delay_amount=4" \\',
        '  -d "delay_unit=week" \\',
        "  -X POST",
      ].join("\n"),
    );
    expectResponseContract(snippetText("Example response:"));
    expectWriteAnalyticsFields(container);
  });

  it("renders the update contract with an executable multiline cURL example", () => {
    const { container } = render(<UpdateWorkflowEmail />);

    expect(screen.getByRole("heading", { name: "PUT /workflows/:workflow_id/emails/:email_id" })).toBeTruthy();
    expect(container.textContent).toContain("subject (optional) Non-empty email subject line");
    expect(container.textContent).toContain("body (optional) HTML email body");
    expect(container.textContent).toContain("delay_amount (optional) Non-negative integer delay");
    expect(container.textContent).toContain(
      'delay_unit (optional) One of "hour", "day", "week", or "month"; requires delay_amount',
    );

    expect(snippetText("cURL example")).toBe(
      [
        "curl https://api.gumroad.com/v2/workflows/0ssD7B0cF6B5XQd3J7lY2A==/emails/bfi_30HLgGWL8H2wo_Gzlg== \\",
        '  -d "access_token=ACCESS_TOKEN" \\',
        '  -d "body=<p>Updated copy.</p>" \\',
        "  -X PUT",
      ].join("\n"),
    );
    expectResponseContract(snippetText("Example response:"));
    expectWriteAnalyticsFields(container);
  });
});
