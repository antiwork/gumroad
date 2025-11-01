import { usePage } from "@inertiajs/react";
import React from "react";

import AdminMerchantAccount, {
  type AdminMerchantAccountProps,
} from "$app/components/Admin/MerchantAccounts/MerchantAccount";

const AdminMerchantAccountsShow = () => {
  const { merchant_account } = usePage<{ merchant_account: AdminMerchantAccountProps }>().props;

  return <AdminMerchantAccount merchantAccount={merchant_account} />;
};

export default AdminMerchantAccountsShow;
