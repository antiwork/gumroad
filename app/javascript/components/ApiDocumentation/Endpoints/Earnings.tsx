import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";

export const GetEarnings = () => (
  <ApiEndpoint
    method="get"
    path="/earnings"
    description="Retrieves an annual earnings breakdown for the authenticated user, matching the totals reported in the Tax Center. Available with the 'view_tax_data' scope. Only available to US-based sellers with the tax center enabled. Fully refunded sales are excluded from every aggregate."
  >
    <ApiParameters>
      <ApiParameter
        name="year"
        description="(required) - A 4-digit tax year. Returns 404 if the year is outside the seller's available range (account-creation year through the previous calendar year)."
      />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "year", type: "integer", description: "The tax year the earnings cover" },
        { name: "currency", type: "string", description: 'Always "usd"' },
        { name: "gross_cents", type: "integer", description: "Gross earnings in cents, summed across all successful non-refunded sales" },
        { name: "fees_cents", type: "integer", description: "Gumroad fees in cents" },
        { name: "taxes_cents", type: "integer", description: "Gumroad-collected and seller-collected taxes in cents" },
        { name: "affiliate_credit_cents", type: "integer", description: "Affiliate credit in cents" },
        { name: "net_cents", type: "integer", description: "gross_cents - fees_cents - taxes_cents - affiliate_credit_cents" },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/earnings \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "year=2025" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "year": 2025,
  "currency": "usd",
  "gross_cents": 123456,
  "fees_cents": 12345,
  "taxes_cents": 678,
  "affiliate_credit_cents": 0,
  "net_cents": 110433
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
