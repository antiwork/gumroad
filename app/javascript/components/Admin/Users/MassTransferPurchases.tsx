import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";

type AdminUserMassTransferPurchasesProps = {
  user: User;
};

const AdminUserMassTransferPurchases = ({ user }: AdminUserMassTransferPurchasesProps) => (
  <>
    <hr />
    <Details>
      <DetailsToggle>
        <h3>Mass-transfer purchases</h3>
      </DetailsToggle>
      <Form
        url={Routes.mass_transfer_purchases_admin_user_path(user.external_id)}
        method="POST"
        confirmMessage="Are you sure you want to Mass Transfer purchases for this user?"
        onSuccess={() => showAlert("Successfully transferred purchases.", "success")}
      >
        {(isLoading) => (
          <Fieldset>
            <div className="grid grid-cols-[1fr_auto] gap-3">
              <Input type="email" name="mass_transfer_purchases[new_email]" placeholder="New email" required />
              <Button type="submit" disabled={isLoading}>
                {isLoading ? "Transferring..." : "Transfer"}
              </Button>
            </div>
            <FieldsetDescription>Are you sure you want to Mass Transfer purchases for this user?</FieldsetDescription>
          </Fieldset>
        )}
      </Form>
    </Details>
  </>
);

export default AdminUserMassTransferPurchases;
