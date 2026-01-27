import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";

type AdminResendReceiptFormProps = {
  purchase_external_id: string;
  email: string;
};

export const AdminResendReceiptForm = ({ purchase_external_id, email }: AdminResendReceiptFormProps) => (
  <Form
    url={Routes.resend_receipt_admin_purchase_path(purchase_external_id)}
    method="POST"
    confirmMessage="Are you sure you want to resend the receipt?"
    onSuccess={() => showAlert("Receipt sent successfully.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div className="flex gap-2">
          <input type="email" className="flex-1" name="resend_receipt[email_address]" placeholder={email} />
          <Button type="submit" disabled={isLoading}>
            {isLoading ? "Sending..." : "Send"}
          </Button>
        </div>
        <small>This will update the purchase email to this new one!</small>
      </fieldset>
    )}
  </Form>
);

export default AdminResendReceiptForm;
