import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, FieldDefinition, renderFields } from "../ApiResponseFields";

const REFUND_POLICY_FIELDS: FieldDefinition[] = [
  { name: "refund_period", type: "string", description: 'One of "none", "7", "14", "30", or "183"' },
  { name: "title", type: "string", description: "Display title derived from the refund period" },
  { name: "fine_print", type: "string | null", description: "Optional fine print, with HTML stripped" },
  {
    name: "in_effect",
    type: "boolean",
    description: "Whether this account-level refund policy is currently shown to buyers",
  },
];

export const GetRefundPolicy = () => (
  <ApiEndpoint method="get" path="/refund_policy" description="Retrieve the account-level refund policy.">
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        {
          name: "refund_policy",
          type: "object",
          description: "The account-level refund policy",
          children: REFUND_POLICY_FIELDS,
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/refund_policy \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "refund_policy": {
    "refund_period": "30",
    "title": "30-day money back guarantee",
    "fine_print": "Refund requests are reviewed within 2 business days.",
    "in_effect": true
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateRefundPolicy = () => (
  <ApiEndpoint
    method="put"
    path="/refund_policy"
    description="Update the account-level refund policy. Requires the edit_products scope. Updates are rejected when the account-level policy is not in effect for the seller."
  >
    <ApiParameters>
      <ApiParameter name="refund_period" description='Required. One of "none", "7", "14", "30", or "183".' />
      <ApiParameter
        name="fine_print"
        description="Optional. Max 3000 characters. HTML is stripped. Send an empty value to clear it."
      />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        {
          name: "refund_policy",
          type: "object",
          description: "The updated account-level refund policy",
          children: REFUND_POLICY_FIELDS,
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/refund_policy \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "refund_period=30" \\
  -d "fine_print=Refund requests are reviewed within 2 business days." \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "refund_policy": {
    "refund_period": "30",
    "title": "30-day money back guarantee",
    "fine_print": "Refund requests are reviewed within 2 business days.",
    "in_effect": true
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
