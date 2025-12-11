import * as React from "react";

import AdminPausePayoutsForm from "$app/components/Admin/Users/PayoutInfo/PausePayoutsForm";
import AdminResumePayoutsForm from "$app/components/Admin/Users/PayoutInfo/ResumePayoutsForm";
import { showAlert } from "$app/components/server-components/Alert";

const AdminTogglePayoutsForm = ({
  user_id,
  payouts_paused_by,
  reason: currentReason,
}: {
  user_id: number;
  payouts_paused_by: "stripe" | "admin" | "system" | "user" | null;
  reason: string | null;
}) => {
  const [pausedBy, setPausedBy] = React.useState(payouts_paused_by);
  const [paused, setPaused] = React.useState(pausedBy && ["admin", "system", "stripe"].includes(pausedBy));

  const [reason, setReason] = React.useState(currentReason);

  const onPaused = (reason: string) => {
    setPausedBy("admin");
    setReason(reason);
    setPaused(true);
    showAlert("Payouts paused", "success");
  };

  const onResumed = () => {
    setPaused(false);
    showAlert("Payouts resumed", "success");
  };

  if (paused) {
    return (
      <AdminResumePayoutsForm user_id={user_id} payouts_paused_by={pausedBy} reason={reason} onSuccess={onResumed} />
    );
  }
  return <AdminPausePayoutsForm user_id={user_id} onSuccess={onPaused} />;
};

export default AdminTogglePayoutsForm;
