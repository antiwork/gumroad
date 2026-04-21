import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";

const TAX_FORM_FIELDS = [
  { name: "tax_year", type: "integer", description: "The tax year the form covers" },
  {
    name: "tax_form_type",
    type: "string",
    description: 'The form type. One of "us_1099_k" or "us_1099_misc".',
  },
  {
    name: "filed_at",
    type: "string",
    description: "ISO-8601 timestamp when Stripe filed the form with the IRS. Null if the form has not yet been filed.",
  },
];

export const GetTaxForms = () => (
  <ApiEndpoint
    method="get"
    path="/tax_forms"
    description="Retrieves tax forms (1099-K, 1099-MISC) generated for the authenticated user. Available with the 'view_tax_data' scope. Only available to US-based sellers with the tax center enabled."
  >
    <ApiParameters>
      <ApiParameter
        name="year"
        description="(optional) - A 4-digit tax year. When omitted, returns forms for every available year. Returns 404 if the year is outside the seller's available range (account-creation year through the previous calendar year)."
      />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        {
          name: "tax_forms",
          type: "array",
          description: "Array of tax form objects",
          children: TAX_FORM_FIELDS,
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/tax_forms \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "year=2025" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "tax_forms": [
    {
      "tax_year": 2025,
      "tax_form_type": "us_1099_k",
      "filed_at": "2026-01-31T00:00:00Z"
    },
    {
      "tax_year": 2025,
      "tax_form_type": "us_1099_misc",
      "filed_at": null
    }
  ]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DownloadTaxForm = () => (
  <ApiEndpoint
    method="get"
    path="/tax_forms/:year/:tax_form_type/download"
    description="Downloads the PDF for a specific tax form. Available with the 'view_tax_data' scope. Response is the raw PDF on success (Content-Type: application/pdf, Content-Disposition: attachment); a JSON error envelope on failure."
  >
    <ApiParameters>
      <ApiParameter name="year" description="(required) - A 4-digit tax year." />
      <ApiParameter
        name="tax_form_type"
        description='(required) - The form type. One of "us_1099_k" or "us_1099_misc".'
      />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/tax_forms/2025/us_1099_k/download \\
  -d "access_token=ACCESS_TOKEN" \\
  -o tax-1099-k-2025.pdf \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example error response (form not found):">
      {`{
  "success": false,
  "message": "Tax form not found."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
