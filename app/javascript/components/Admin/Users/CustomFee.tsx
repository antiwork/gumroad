import * as React from "react";

import { Form } from "$app/components/Admin/Form";
import type { User } from "$app/components/Admin/Users/User";
import { useClientAlert } from "$app/components/ClientAlertProvider";

type AdminUserCustomFeeProps = {
  user: User;
};

const AdminUserCustomFee = ({ user }: AdminUserCustomFeeProps) => {
  const { showAlert } = useClientAlert();
  const initialCustomFee = user.custom_fee_per_thousand ? user.custom_fee_per_thousand / 10 : "";
  const [customFee, setCustomFee] = React.useState(initialCustomFee);

  return (
    <>
      <hr />
      <details>
        <summary>
          <h3>Custom fee</h3>
        </summary>
        <Form
          url={Routes.set_custom_fee_admin_user_path(user.id)}
          method="POST"
          confirmMessage={`Are you sure you want to update this user's custom fee?`}
          onSuccess={() => showAlert("Custom fee updated.", "success")}
        >
          {(isLoading) => (
            <fieldset>
              <div className="input-with-button" style={{ alignItems: "start" }}>
                <input
                  name="custom_fee_percent"
                  type="number"
                  inputMode="decimal"
                  min="0"
                  max="100"
                  step="0.1"
                  value={customFee}
                  onChange={(e) => setCustomFee(e.target.value)}
                  placeholder="Enter a custom fee percentage between 0 and 100. Submit blank to clear existing custom fee."
                />
                <button type="submit" className="button" disabled={isLoading} id="update-custom-fee">
                  {isLoading ? "Submitting..." : "Submit"}
                </button>
              </div>
              <small>
                Note: Updated custom fee will apply to new direct (non-discover) sales of the user, but not to future
                charges of their existing memberships.
              </small>
            </fieldset>
          )}
        </Form>
      </details>
    </>
  );
};

export default AdminUserCustomFee;
