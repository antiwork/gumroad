import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { INSTALLMENT_FIELDS } from "../responseFieldDefinitions";

const AUDIENCE_PARAMETER_DESCRIPTION = [
  '(optional, "all", "audience", "customers", "seller", "followers", "follower", or "product")',
  'Default: "audience"',
].join(" ");

const InstallmentResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "installment",
        type: "object",
        description: "The email object",
        children: INSTALLMENT_FIELDS,
      },
    ])}
  </ApiResponseFields>
);

const InstallmentsResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "installments",
        type: "array",
        description: "Array of email objects",
        children: INSTALLMENT_FIELDS,
      },
      {
        name: "next_page_key",
        type: "string",
        description: "Cursor for the next page",
        condition: "present when more results exist",
      },
      {
        name: "next_page_url",
        type: "string",
        description: "URL for the next page",
        condition: "present when more results exist",
      },
    ])}
  </ApiResponseFields>
);

const PreviewResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "installment",
        type: "object",
        description: "The email object",
        children: INSTALLMENT_FIELDS,
      },
      {
        name: "preview_url",
        type: "string | null",
        description: "Public post URL when published, otherwise the seller edit URL",
      },
      { name: "message", type: "string", description: "Preview delivery message" },
    ])}
  </ApiResponseFields>
);

export const GetEmails = () => (
  <ApiEndpoint
    method="get"
    path="/installments"
    description="Retrieve the seller's audience emails. Use type to filter by published, scheduled, or draft emails."
  >
    <ApiParameters>
      <ApiParameter name="type" description='(optional, "published", "scheduled", or "draft")' />
      <ApiParameter name="page_key" description="(optional) Cursor returned by the previous page" />
    </ApiParameters>
    <InstallmentsResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/installments \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "type=draft" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad email list --type draft</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "installments": [{
    "id": "bfi_30HLgGWL8H2wo_Gzlg==",
    "subject": "Launch update",
    "message": "<p>Hello, world!</p>",
    "audience_type": "audience",
    "product_id": null,
    "state": "draft",
    "published_at": null,
    "scheduled_at": null,
    "send_emails": true,
    "shown_on_profile": false,
    "audience_count": null,
    "recipients_count": null,
    "url": null,
    "created_at": "2026-06-17T12:00:00.000Z",
    "updated_at": "2026-06-17T12:00:00.000Z"
  }]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetEmail = () => (
  <ApiEndpoint method="get" path="/installments/:id" description="Retrieve the details of a specific audience email.">
    <InstallmentResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/installments/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad email view bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "installment": {
    "id": "bfi_30HLgGWL8H2wo_Gzlg==",
    "subject": "Launch update",
    "message": "<p>Hello, world!</p>",
    "audience_type": "audience",
    "product_id": null,
    "state": "draft",
    "published_at": null,
    "scheduled_at": null,
    "send_emails": true,
    "shown_on_profile": false,
    "audience_count": null,
    "recipients_count": null,
    "url": null,
    "created_at": "2026-06-17T12:00:00.000Z",
    "updated_at": "2026-06-17T12:00:00.000Z"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const CreateEmail = () => (
  <ApiEndpoint
    method="post"
    path="/installments"
    description="Create a draft audience email, or send it immediately by passing publish=true or draft=false."
  >
    <ApiParameters>
      <ApiParameter name="subject" description="Email subject line" />
      <ApiParameter name="body" description="HTML email body" />
      <ApiParameter name="audience" description={AUDIENCE_PARAMETER_DESCRIPTION} />
      <ApiParameter name="product_id" description="Required when audience is product" />
      <ApiParameter name="link_id" description="Product permalink accepted when audience is product" />
      <ApiParameter name="send_emails" description="(optional, true or false) Default: true" />
      <ApiParameter name="publish" description="(optional, true to send immediately)" />
      <ApiParameter name="draft" description="(optional, false to send immediately)" />
    </ApiParameters>
    <InstallmentResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/installments \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "subject=Launch update" \\
  -d "body=<p>Hello, world!</p>" \\
  -d "audience=audience" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad email create \\
  --subject "Launch update" \\
  --body "<p>Hello, world!</p>" \\
  --audience audience`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "installment": {
    "id": "bfi_30HLgGWL8H2wo_Gzlg==",
    "subject": "Launch update",
    "message": "<p>Hello, world!</p>",
    "audience_type": "audience",
    "product_id": null,
    "state": "draft",
    "published_at": null,
    "scheduled_at": null,
    "send_emails": true,
    "shown_on_profile": false,
    "audience_count": null,
    "recipients_count": null,
    "url": null,
    "created_at": "2026-06-17T12:00:00.000Z",
    "updated_at": "2026-06-17T12:00:00.000Z"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const PreviewEmail = () => (
  <ApiEndpoint
    method="post"
    path="/installments/:id/preview"
    description="Send a preview of an audience email to the seller's email address."
  >
    <PreviewResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/installments/bfi_30HLgGWL8H2wo_Gzlg==/preview \\
  -d "access_token=ACCESS_TOKEN" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad email preview bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "installment": {
    "id": "bfi_30HLgGWL8H2wo_Gzlg==",
    "subject": "Launch update",
    "message": "<p>Hello, world!</p>",
    "audience_type": "audience",
    "product_id": null,
    "state": "draft",
    "published_at": null,
    "scheduled_at": null,
    "send_emails": true,
    "shown_on_profile": false,
    "audience_count": null,
    "recipients_count": null,
    "url": null,
    "created_at": "2026-06-17T12:00:00.000Z",
    "updated_at": "2026-06-17T12:00:00.000Z"
  },
  "preview_url": "/emails/bfi_30HLgGWL8H2wo_Gzlg==/edit?preview_post=true",
  "message": "A preview has been sent to your email."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const SendEmail = () => (
  <ApiEndpoint
    method="post"
    path="/installments/:id/send"
    description="Publish a draft audience email and send it to its audience."
  >
    <InstallmentResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/installments/bfi_30HLgGWL8H2wo_Gzlg==/send \\
  -d "access_token=ACCESS_TOKEN" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad email send bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "installment": {
    "id": "bfi_30HLgGWL8H2wo_Gzlg==",
    "subject": "Launch update",
    "message": "<p>Hello, world!</p>",
    "audience_type": "audience",
    "product_id": null,
    "state": "published",
    "published_at": "2026-06-17T12:15:00.000Z",
    "scheduled_at": null,
    "send_emails": true,
    "shown_on_profile": false,
    "audience_count": null,
    "recipients_count": 0,
    "url": "/seller/p/launch-update",
    "created_at": "2026-06-17T12:00:00.000Z",
    "updated_at": "2026-06-17T12:15:00.000Z"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteEmail = () => (
  <ApiEndpoint method="delete" path="/installments/:id" description="Delete an audience email.">
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "message", type: "string", description: "Deletion confirmation message" },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/installments/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad email delete bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The installment was deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
