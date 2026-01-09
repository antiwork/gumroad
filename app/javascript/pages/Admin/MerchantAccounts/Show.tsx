import { Link, usePage } from "@inertiajs/react";
import { capitalize } from "lodash-es";
import React from "react";
import { cast } from "ts-safe-cast";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { BooleanIcon, NoIcon } from "$app/components/Admin/Icons";
import { Alert } from "$app/components/ui/Alert";

export type AdminMerchantAccountProps = {
  charge_processor_id: string;
  charge_processor_merchant_id: string | null;
  created_at: string;
  external_id: string;
  user_id: number | null;
  country: string;
  country_name: string | null;
  currency: string;
  holder_of_funds: string;
  stripe_account_url: string | null;
  charge_processor_alive_at: string | null;
  charge_processor_verified_at: string | null;
  charge_processor_deleted_at: string | null;
  updated_at: string;
  deleted_at: string | null;
  live_attributes: { label: string; value: unknown }[];
};

const AdminMerchantAccountsShow = () => {
  const { merchant_account } = cast<{ merchant_account: AdminMerchantAccountProps }>(usePage().props);

  return (
    <div className="override grid gap-4 rounded border border-border bg-background p-4">
      <div>
        <h2>Merchant Account {merchant_account.external_id}</h2>
        <DateTimeWithRelativeTooltip date={merchant_account.created_at} utc />
      </div>

      <hr />
      <div>
        <dl>
          <dt>External ID</dt>
          <dd>{merchant_account.external_id}</dd>

          <dt>User</dt>
          <dd>
            {merchant_account.user_id ? (
              <Link href={Routes.admin_user_path(merchant_account.user_id)}>{merchant_account.user_id}</Link>
            ) : (
              "none"
            )}
          </dd>

          <dt>Country</dt>
          <dd>
            {merchant_account.country_name} ({merchant_account.country})
          </dd>

          <dt>Currency</dt>
          <dd>{merchant_account.currency.toUpperCase()}</dd>

          <dt>Active</dt>
          <dd>
            <BooleanIcon value={!!merchant_account.deleted_at} />
          </dd>

          <dt>Funds are held by</dt>
          <dd>{capitalize(merchant_account.holder_of_funds)}</dd>

          <dt>Charge Processor</dt>
          <dd>
            {capitalize(merchant_account.charge_processor_id)}{" "}
            {merchant_account.charge_processor_merchant_id && merchant_account.stripe_account_url ? (
              <a href={merchant_account.stripe_account_url} target="_blank" rel="noopener noreferrer">
                {merchant_account.charge_processor_merchant_id}
              </a>
            ) : null}
          </dd>

          <dt>{capitalize(merchant_account.charge_processor_id)} Alive</dt>
          <dd>
            <BooleanIcon value={!!merchant_account.charge_processor_alive_at} />{" "}
            <DateTimeWithRelativeTooltip date={merchant_account.charge_processor_alive_at} utc />
          </dd>

          <dt>{capitalize(merchant_account.charge_processor_id)} Verified</dt>
          <dd>
            <BooleanIcon value={!!merchant_account.charge_processor_verified_at} />{" "}
            <DateTimeWithRelativeTooltip date={merchant_account.charge_processor_verified_at} utc />
          </dd>

          <dt>{capitalize(merchant_account.charge_processor_id)} Deleted</dt>
          <dd>
            <BooleanIcon value={!!merchant_account.charge_processor_deleted_at} />{" "}
            <DateTimeWithRelativeTooltip date={merchant_account.charge_processor_deleted_at} utc />
          </dd>
        </dl>
      </div>

      <hr />
      <div className="flex flex-col gap-4">
        <h3>Charge Processor live attributes</h3>
        {merchant_account.live_attributes.length > 0 ? (
          <dl>
            {merchant_account.live_attributes.map(({ label, value }) => (
              <React.Fragment key={label}>
                <dt>{label}</dt>
                <dd>
                  <code>{JSON.stringify(value)}</code>
                </dd>
              </React.Fragment>
            ))}
          </dl>
        ) : (
          <Alert variant="info">Charge Processor Merchant information is missing.</Alert>
        )}
      </div>

      <hr />
      <div>
        <dl>
          <dt>Updated</dt>
          <dd>
            <DateTimeWithRelativeTooltip date={merchant_account.updated_at} utc />
          </dd>
        </dl>

        <dl>
          <dt>Deleted</dt>
          <dd>
            <DateTimeWithRelativeTooltip date={merchant_account.deleted_at} utc placeholder={<NoIcon />} />
          </dd>
        </dl>
      </div>
    </div>
  );
};

export default AdminMerchantAccountsShow;
