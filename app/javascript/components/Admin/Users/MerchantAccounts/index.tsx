import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import AdminActionButton from "$app/components/Admin/ActionButton";
import Loading from "$app/components/Admin/Loading";
import MerchantAccount, {
  type MerchantAccountProps,
} from "$app/components/Admin/Users/MerchantAccounts/MerchantAccount";
import type { User } from "$app/components/Admin/Users/User";

type AdminUserMerchantAccountsProps = {
  user: User;
};

type AdminUserMerchantAccountsData = {
  has_stripe_account: boolean;
  merchant_accounts: MerchantAccountProps[];
};

type MerchantAccountsContentProps = {
  user: User;
  merchant_accounts: MerchantAccountProps[];
  has_stripe_account: boolean;
  isLoading: boolean;
};

const MerchantAccountsContent = ({
  user,
  merchant_accounts,
  has_stripe_account,
  isLoading,
}: MerchantAccountsContentProps) => {
  if (isLoading) {
    return <Loading />;
  }

  return (
    <>
      {merchant_accounts.length > 0 ? (
        <ul className="inline">
          {merchant_accounts.map((merchant_account) => (
            <MerchantAccount key={merchant_account.id} {...merchant_account} />
          ))}
        </ul>
      ) : (
        <div className="info" role="status">
          No merchant accounts.
        </div>
      )}

      {!has_stripe_account && (
        <div className="button-group mt-2">
          <AdminActionButton
            label="Create Managed Account"
            url={Routes.create_stripe_managed_account_admin_user_path(user.id)}
            confirm_message={`Are you sure you want to create a Stripe Managed Account for user ${user.id}?`}
            class="button-stripe"
          />
        </div>
      )}
    </>
  );
};

const AdminUserMerchantAccounts = ({ user }: AdminUserMerchantAccountsProps) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [data, setData] = React.useState<AdminUserMerchantAccountsData>({
    has_stripe_account: false,
    merchant_accounts: [],
  });

  const fetchMerchantAccounts = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: Routes.admin_user_merchant_accounts_path(user.id),
      accept: "json",
    });
    setData(cast<AdminUserMerchantAccountsData>(await response.json()));
    setIsLoading(false);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchMerchantAccounts();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Merchant Accounts</h3>
        </summary>
        <MerchantAccountsContent
          user={user}
          isLoading={isLoading}
          merchant_accounts={data.merchant_accounts}
          has_stripe_account={data.has_stripe_account}
        />
      </details>
    </>
  );
};

export default AdminUserMerchantAccounts;
