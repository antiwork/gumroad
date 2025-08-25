import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

const AdminUserPurchasesTab = ({ is_affiliate_user }: { is_affiliate_user: boolean }) => (
  <div className="paragraphs">
    <h3>{is_affiliate_user ? "All affiliate purchases" : "All purchases"}</h3>
    <div className="info" role="status">
      Purchases aggregation coming soon. For now, view individual product purchases in the Products tab.
    </div>
  </div>
);

export default register({ component: AdminUserPurchasesTab, propParser: createCast() });
