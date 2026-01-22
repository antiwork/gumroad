import { Link } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import AdminActionButton from "$app/components/Admin/ActionButton";
import { BooleanIcon } from "$app/components/Admin/Icons";
import type { User } from "$app/components/Admin/Users/User";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Alert } from "$app/components/ui/Alert";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

type AdminUserMerchantAccountsProps = {
  user: User;
};

type AdminUserMerchantAccountsData = {
  has_stripe_account: boolean;
  merchant_accounts: MerchantAccountProps[];
};

export type MerchantAccountProps = {
  external_id: string;
  charge_processor_id: string;
  alive: boolean;
  charge_processor_alive: boolean;
};

const MerchantAccount = ({ external_id, charge_processor_id, alive, charge_processor_alive }: MerchantAccountProps) => (
  <li>
    <Link href={Routes.admin_merchant_account_path(external_id)}>
      {external_id} - {charge_processor_id}
    </Link>{" "}
    <BooleanIcon value={alive ? charge_processor_alive : false} />
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
        url: Routes.admin_user_merchant_accounts_path(user.external_id),
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

      {isLoading ? <LoadingSpinner /> : null}

      {data?.merchant_accounts && data.merchant_accounts.length > 0 ? (
        <ul className="inline">
          {data.merchant_accounts.map((merchant_account: MerchantAccountProps) => (
            <MerchantAccount key={merchant_account.external_id} {...merchant_account} />
          ))}
        </ul>
      ) : (
        <Alert role="status" variant="info">
          No merchant accounts.
        </Alert>
      )}

      {!data?.has_stripe_account && (
        <div className="mt-2 flex flex-wrap gap-2">
          <AdminActionButton
            label="Create Managed Account"
            url={Routes.create_stripe_managed_account_admin_user_path(user.external_id)}
            confirm_message={`Are you sure you want to create a Stripe Managed Account for user ${user.external_id}?`}
            class="button-stripe"
          />
        </div>
      )}
    </div>
  );
};

export default AdminUserMerchantAccounts;
