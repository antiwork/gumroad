import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { WORKFLOW_DETAIL_FIELDS, WORKFLOW_EMAIL_FIELDS, WORKFLOW_FIELDS } from "../responseFieldDefinitions";

const WorkflowsResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "workflows",
        type: "array",
        description: "Array of workflow objects",
        children: WORKFLOW_FIELDS,
      },
    ])}
  </ApiResponseFields>
);

const WorkflowResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "workflow",
        type: "object",
        description: "The workflow object with its email steps",
        children: WORKFLOW_DETAIL_FIELDS,
      },
    ])}
  </ApiResponseFields>
);

const WorkflowEmailResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "email",
        type: "object",
        description: "The created or updated workflow email",
        children: WORKFLOW_EMAIL_FIELDS,
      },
    ])}
  </ApiResponseFields>
);

export const GetWorkflows = () => (
  <ApiEndpoint
    method="get"
    path="/workflows"
    description="Retrieve the seller's active workflows in newest-first order. Requires the edit_emails or account scope."
  >
    <WorkflowsResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/workflows \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "workflows": [{
    "id": "0ssD7B0cF6B5XQd3J7lY2A==",
    "name": "Customer onboarding",
    "audience_type": "product",
    "trigger": null,
    "product_id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "variant_id": null,
    "state": "published",
    "published_at": "2026-07-10T12:00:00.000Z",
    "first_published_at": "2026-07-10T12:00:00.000Z",
    "send_to_past_customers": true,
    "emails_count": 2,
    "filters": {
      "paid_more_than": "20"
    },
    "created_at": "2026-07-10T11:45:00.000Z",
    "updated_at": "2026-07-10T12:00:00.000Z"
  }]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetWorkflow = () => (
  <ApiEndpoint
    method="get"
    path="/workflows/:id"
    description="Retrieve one active workflow with its email steps and delivery statistics. Requires the edit_emails or account scope."
  >
    <WorkflowResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/workflows/0ssD7B0cF6B5XQd3J7lY2A== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "workflow": {
    "id": "0ssD7B0cF6B5XQd3J7lY2A==",
    "name": "Customer onboarding",
    "audience_type": "product",
    "trigger": null,
    "product_id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "variant_id": null,
    "state": "published",
    "published_at": "2026-07-10T12:00:00.000Z",
    "first_published_at": "2026-07-10T12:00:00.000Z",
    "send_to_past_customers": true,
    "emails_count": 2,
    "filters": {
      "paid_more_than": "20"
    },
    "created_at": "2026-07-10T11:45:00.000Z",
    "updated_at": "2026-07-10T12:00:00.000Z",
    "emails": [{
      "id": "bfi_30HLgGWL8H2wo_Gzlg==",
      "subject": "Welcome",
      "message": "<p>Thanks for joining.</p>",
      "audience_type": "product",
      "product_id": "A-m3CDDC5dlrSdKZp0RFhA==",
      "state": "published",
      "published_at": "2026-07-10T12:00:00.000Z",
      "send_emails": true,
      "delay": {
        "amount": 1,
        "unit": "day"
      },
      "sent_count": 100,
      "open_count": 42,
      "open_rate": 42.0,
      "click_count": 8,
      "click_rate": 8.0,
      "created_at": "2026-07-10T11:50:00.000Z",
      "updated_at": "2026-07-10T12:00:00.000Z"
    }]
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const CreateWorkflowEmail = () => (
  <ApiEndpoint
    method="post"
    path="/workflows/:workflow_id/emails"
    description="Add one email step. The step inherits the workflow state. If send_to_past_customers is true, a published workflow schedules eligible past recipients at once. Abandoned cart workflows do not support added steps. Requires the edit_emails or account scope."
  >
    <ApiParameters>
      <ApiParameter name="subject" description="Email subject line" />
      <ApiParameter name="body" description="HTML email body" />
      <ApiParameter name="delay_amount" description="Non-negative integer delay after the workflow trigger" />
      <ApiParameter name="delay_unit" description='One of "hour", "day", "week", or "month"' />
    </ApiParameters>
    <WorkflowEmailResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/workflows/0ssD7B0cF6B5XQd3J7lY2A==/emails \
  -d "access_token=ACCESS_TOKEN" \
  -d "subject=Week four" \
  -d "body=<p>Keep going.</p>" \
  -d "delay_amount=4" \
  -d "delay_unit=week" \
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "email": {
    "id": "bfi_30HLgGWL8H2wo_Gzlg==",
    "subject": "Week four",
    "message": "<p>Keep going.</p>",
    "audience_type": "product",
    "product_id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "state": "published",
    "published_at": "2026-08-06T12:00:00.000Z",
    "send_emails": true,
    "delay": { "amount": 4, "unit": "week" },
    "sent_count": 0,
    "open_count": null,
    "open_rate": null,
    "click_count": null,
    "click_rate": null,
    "created_at": "2026-08-06T12:00:00.000Z",
    "updated_at": "2026-08-06T12:00:00.000Z"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateWorkflowEmail = () => (
  <ApiEndpoint
    method="put"
    path="/workflows/:workflow_id/emails/:email_id"
    description="Update one email step. Omitted fields stay unchanged. A delay change can reschedule recipients for a published workflow. Abandoned cart workflows do not support delay changes. The endpoint does not change workflow state. Requires the edit_emails or account scope."
  >
    <ApiParameters>
      <ApiParameter name="subject" description="(optional) Email subject line" />
      <ApiParameter name="body" description="(optional) HTML email body" />
      <ApiParameter name="delay_amount" description="(optional) Non-negative integer delay; requires delay_unit" />
      <ApiParameter
        name="delay_unit"
        description='(optional) One of "hour", "day", "week", or "month"; requires delay_amount'
      />
    </ApiParameters>
    <WorkflowEmailResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/workflows/0ssD7B0cF6B5XQd3J7lY2A==/emails/bfi_30HLgGWL8H2wo_Gzlg== \
  -d "access_token=ACCESS_TOKEN" \
  -d "body=<p>Updated copy.</p>" \
  -X PUT`}
    </CodeSnippet>
  </ApiEndpoint>
);
