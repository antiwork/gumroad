import { Link } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import AdminActionButton from "$app/components/Admin/ActionButton";
import { YesIcon, NoIcon } from "$app/components/Admin/Icons";
import AdminLoading from "$app/components/Admin/Loading";
import type { User } from "$app/components/Admin/Users/User";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

type AdminUserMerchantAccountsProps = {
  user: User;
};

type AdminUserMerchantAccountsData = {
  has_stripe_account: boolean;
  merchant_accounts: MerchantAccountProps[];
};

export type MerchantAccountProps = {
  id: number;
  charge_processor_id: string;
  alive: boolean;
  charge_processor_alive: boolean;
};

const MerchantAccount = ({ id, charge_processor_id, alive, charge_processor_alive }: MerchantAccountProps) => (
  <li>
    <Link href={Routes.admin_merchant_account_path(id)}>
      {id} - {charge_processor_id}
    </Link>{" "}
    {alive && charge_processor_alive ? <YesIcon /> : <NoIcon />}
  </li>
);

const AdminUserMerchantAccounts = ({ user }: AdminUserMerchantAccountsProps) => {
  const [isLoading, setIsLoading] = React.useState(false);
  const [data, setData] = React.useState<AdminUserMerchantAccountsData | null>(null);

  const elementRef = useIsIntersecting<HTMLDivElement>((isIntersecting) => {
    if (!isIntersecting || data) return;

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

    void fetchMerchantAccounts();
  });

  return (
    <div ref={elementRef}>
      <h3>Merchant Accounts</h3>

      {isLoading ? <AdminLoading /> : null}

      {data?.merchant_accounts && data.merchant_accounts.length > 0 ? (
        <ul className="inline">
          {data.merchant_accounts.map((merchant_account: MerchantAccountProps) => (
            <MerchantAccount key={merchant_account.id} {...merchant_account} />
          ))}
        </ul>
      ) : (
        <div className="info" role="status">
          No merchant accounts.
        </div>
      )}

      {!data?.has_stripe_account && (
        <div className="button-group mt-2">
          <AdminActionButton
            label="Create Managed Account"
            url={Routes.create_stripe_managed_account_admin_user_path(user.id)}
            confirm_message={`Are you sure you want to create a Stripe Managed Account for user ${user.id}?`}
            class="button-stripe"
          />
        </div>
      )}
    </div>
  );
};

export default AdminUserMerchantAccounts;
