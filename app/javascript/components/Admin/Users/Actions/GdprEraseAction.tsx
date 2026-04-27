import React from "react";

import AdminAction from "$app/components/Admin/ActionButton";
import { type User } from "$app/components/Admin/Users/User";

type GdprEraseActionProps = {
  user: User;
};

const GdprEraseAction = ({ user: { external_id } }: GdprEraseActionProps) => (
  <AdminAction
    label="GDPR Erase"
    url={Routes.gdpr_erase_admin_user_path(external_id)}
    confirm_message={
      "⚠️ GDPR DATA ERASURE\n\n" +
      "This will permanently:\n" +
      "• Anonymize all personal data (name, email, address, IP, etc.)\n" +
      "• Delete all products\n" +
      "• Cancel all subscriptions\n" +
      "• Anonymize buyer purchase records\n" +
      "• Deactivate the account\n\n" +
      "Transaction records are retained for tax/legal compliance.\n\n" +
      "After this, you must also clean up:\n" +
      "• Helper/Supabase (customer conversations)\n" +
      "• Gmail (correspondence)\n" +
      "• Stripe (customer data)\n\n" +
      "This action CANNOT be undone. Are you sure?"
    }
    done="Erased"
    success_message="GDPR erasure complete. External cleanup still needed: Helper/Supabase, Gmail, Stripe."
    color="danger"
  />
);

export default GdprEraseAction;
