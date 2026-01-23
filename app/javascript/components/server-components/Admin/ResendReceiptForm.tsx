import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";
import { Input } from "$app/components/ui/Input";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";

export const AdminResendReceiptForm = ({ purchase_id, email }: { purchase_id: number; email: string }) => (
  <Form
    url={Routes.resend_receipt_admin_purchase_path(purchase_id)}
    method="POST"
    confirmMessage="Are you sure you want to resend the receipt?"
    onSuccess={() => showAlert("Receipt sent successfully.", "success")}
  >
    {(isLoading) => (
      <Fieldset>
        <div className="input-with-button">
          <Input type="email" name="resend_receipt[email_address]" placeholder={email} />
          <Button type="submit" disabled={isLoading}>
            {isLoading ? "Sending..." : "Send"}
          </Button>
        </div>
        <FieldsetDescription>This will update the purchase email to this new one!</FieldsetDescription>
      </Fieldset>
    )}
  </Form>
);

export default register({ component: AdminResendReceiptForm, propParser: createCast() });
