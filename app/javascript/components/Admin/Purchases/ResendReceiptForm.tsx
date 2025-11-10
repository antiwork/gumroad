import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";

type AdminResendReceiptFormProps = {
  purchase_id: number;
  email: string;
};

export const AdminResendReceiptForm = ({ purchase_id, email }: AdminResendReceiptFormProps) => (
  <Form
    url={Routes.resend_receipt_admin_purchase_path(purchase_id)}
    method="POST"
    confirmMessage="Are you sure you want to resend the receipt?"
    onSuccess={() => showAlert("Receipt sent successfully.", "success")}
  >
    {(isLoading) => (
      <fieldset>
        <div className="input-with-button">
          <input type="email" name="resend_receipt[email_address]" placeholder={email} />
          <button type="submit" className="button" disabled={isLoading}>
            {isLoading ? "Sending..." : "Send"}
          </button>
        </div>
        <small>This will update the purchase email to this new one!</small>
      </fieldset>
    )}
  </Form>
);

export default AdminResendReceiptForm;
