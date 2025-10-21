import * as React from "react";

import { Form } from "$app/components/Admin/Form";

const AdminPausePayoutsForm = ({ user_id, onSuccess }: { user_id: number; onSuccess: (reason: string) => void }) => {
  const [reason, setReason] = React.useState("");
  const onReasonChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    setReason(e.target.value);
  };

  const onPauseSuccess = () => {
    onSuccess(reason);
  };

  return (
    <Form
      url={Routes.pause_admin_user_payouts_path(user_id)}
      method="POST"
      confirmMessage={`Are you sure you want to pause payouts for user ${user_id}?`}
      onSuccess={onPauseSuccess}
    >
      {(isLoading) => (
        <fieldset>
          <div className="input-with-button !items-end">
            <div className="grid gap-2">
              <textarea
                name="pause_payouts[reason]"
                rows={2}
                placeholder="Add a reason for pausing payouts. It'll be displayed to the user on their dashboard."
                value={reason}
                onChange={onReasonChange}
              />
            </div>
            <button type="submit" className="button" disabled={isLoading}>
              {isLoading ? "Pausing Payouts" : "Pause Payouts"}
            </button>
          </div>
        </fieldset>
      )}
    </Form>
  );
};

export default AdminPausePayoutsForm;
