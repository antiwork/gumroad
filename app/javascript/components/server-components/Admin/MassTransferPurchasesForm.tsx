import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Form } from "$app/components/server-components/Admin/Form";
import { showAlert } from "$app/components/server-components/Alert";
import { Input } from "$app/components/ui/Input";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";

export const MassTransferPurchasesForm = ({ user_id }: { user_id: number }) => (
  <Form
    url={Routes.mass_transfer_purchases_admin_user_path(user_id)}
    method="POST"
    confirmMessage="Are you sure you want to Mass Transfer purchases for this user?"
    onSuccess={() => showAlert("Successfully transferred purchases.", "success")}
  >
    {(isLoading) => (
      <Fieldset>
        <div style={{ display: "grid", gap: "var(--spacer-3)", gridTemplateColumns: "1fr auto" }}>
          <Input type="email" name="mass_transfer_purchases[new_email]" placeholder="New email" required />
          <Button type="submit" disabled={isLoading}>
            {isLoading ? "Transferring..." : "Transfer"}
          </Button>
        </div>
        <FieldsetDescription>Are you sure you want to Mass Transfer purchases for this user?</FieldsetDescription>
      </Fieldset>
    )}
  </Form>
);

export default register({ component: MassTransferPurchasesForm, propParser: createCast() });
