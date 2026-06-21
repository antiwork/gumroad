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

const EmailResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "email",
        type: "object",
        description: "The email object",
        children: INSTALLMENT_FIELDS,
      },
    ])}
  </ApiResponseFields>
);

const EmailsResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "emails",
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
        name: "email",
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
    path="/emails"
    description="Retrieve the seller's audience emails. Use type to filter by published, scheduled, or draft emails. Requires the edit_emails or account scope."
  >
    <ApiParameters>
      <ApiParameter name="type" description='(optional, "published", "scheduled", or "draft")' />
      <ApiParameter name="page_key" description="(optional) Cursor returned by the previous page" />
    </ApiParameters>
    <EmailsResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/emails \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "type=draft" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad emails list --type draft</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "emails": [{
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
  <ApiEndpoint
    method="get"
    path="/emails/:id"
    description="Retrieve the details of a specific audience email. Requires the edit_emails or account scope."
  >
    <EmailResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/emails/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad emails view bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "email": {
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
    path="/emails"
    description="Create a draft audience email, or send it immediately by passing publish=true (or draft=false). Scheduled emails can only be created in the Emails web editor. Requires the edit_emails or account scope."
  >
    <ApiParameters>
      <ApiParameter name="subject" description="Email subject line" />
      <ApiParameter name="body" description="HTML email body" />
      <ApiParameter name="audience" description={AUDIENCE_PARAMETER_DESCRIPTION} />
      <ApiParameter name="product_id" description="Required when audience is product" />
      <ApiParameter name="link_id" description="Product permalink accepted when audience is product" />
      <ApiParameter name="publish" description="(optional, true to send immediately)" />
      <ApiParameter name="draft" description="(optional, false to send immediately)" />
    </ApiParameters>
    <EmailResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/emails \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "subject=Launch update" \\
  -d "body=<p>Hello, world!</p>" \\
  -d "audience=all" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad emails create \\
  --subject "Launch update" \\
  --body ./email.html \\
  --audience all`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "email": {
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
    path="/emails/:id/preview"
    description="Send a preview of an audience email to the seller's email address. Requires the edit_emails or account scope."
  >
    <PreviewResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/emails/bfi_30HLgGWL8H2wo_Gzlg==/preview \\
  -d "access_token=ACCESS_TOKEN" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad emails send-preview bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "email": {
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
  "preview_url": "https://gumroad.com/emails/bfi_30HLgGWL8H2wo_Gzlg==/edit?preview_post=true",
  "message": "A preview has been sent to your email."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const SendEmail = () => (
  <ApiEndpoint
    method="post"
    path="/emails/:id/send"
    description="Publish a draft audience email and send it to its audience. Requires the edit_emails or account scope."
  >
    <EmailResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/emails/bfi_30HLgGWL8H2wo_Gzlg==/send \\
  -d "access_token=ACCESS_TOKEN" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad emails send bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "email": {
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
    "url": "https://seller.gumroad.com/p/launch-update",
    "created_at": "2026-06-17T12:00:00.000Z",
    "updated_at": "2026-06-17T12:15:00.000Z"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteEmail = () => (
  <ApiEndpoint
    method="delete"
    path="/emails/:id"
    description="Delete an audience email. Requires the edit_emails or account scope."
  >
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "message", type: "string", description: "Deletion confirmation message" },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/emails/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad emails delete bfi_30HLgGWL8H2wo_Gzlg==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The email was deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
