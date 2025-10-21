import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { useClientAlert } from "$app/components/ClientAlertProvider";

type AdminUserMassTransferPurchasesProps = {
  user: User;
};

const AdminUserMassTransferPurchases = ({ user }: AdminUserMassTransferPurchasesProps) => {
  const { showAlert } = useClientAlert();

  return (
    <>
      <hr />
      <details>
        <summary>
          <h3>Mass-transfer purchases</h3>
        </summary>
        <Form
          url={Routes.mass_transfer_purchases_admin_user_path(user.id)}
          method="POST"
          confirmMessage="Are you sure you want to Mass Transfer purchases for this user?"
          onSuccess={() => showAlert("Successfully transferred purchases.", "success")}
        >
          {(isLoading) => (
            <fieldset>
              <div className="grid grid-cols-[1fr_auto] gap-3">
                <input type="email" name="mass_transfer_purchases[new_email]" placeholder="New email" required />
                <button type="submit" className="button" disabled={isLoading}>
                  {isLoading ? "Transferring..." : "Transfer"}
                </button>
              </div>
              <small>Are you sure you want to Mass Transfer purchases for this user?</small>
            </fieldset>
          )}
        </Form>
      </details>
    </>
  );
};

export default AdminUserMassTransferPurchases;
