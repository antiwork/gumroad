import { Link } from "@inertiajs/react";
import { capitalize } from "lodash";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { BooleanIcon, NoIcon } from "$app/components/Admin/Icons";

export type AdminMerchantAccountProps = {
  id: number;
  charge_processor_id: string;
  charge_processor_merchant_id: string;
  created_at: string;
  external_id: string;
  user_id: number;
  country: string;
  country_name: string;
  currency: string;
  holder_of_funds: string;
  stripe_account_url: string;
  charge_processor_alive_at: string;
  charge_processor_verified_at: string;
  charge_processor_deleted_at: string;
  updated_at: string;
  deleted_at: string;
  live_attributes: Record<string, unknown>;
};

const AdminMerchantAccount = ({ merchantAccount }: { merchantAccount: AdminMerchantAccountProps }) => (
  <div className="override grid gap-4 rounded border border-border bg-background p-4">
    <div>
      <h2>Merchant Account {merchantAccount.id}</h2>
      <DateTimeWithRelativeTooltip date={merchantAccount.created_at} utc />
    </div>

    <hr />
    <div>
      <dl>
        <dt>ID</dt>
        <dd>{merchantAccount.id}</dd>

        <dt>External ID</dt>
        <dd>{merchantAccount.external_id}</dd>

        <dt>User</dt>
        <dd>
          {merchantAccount.user_id ? (
            <Link href={Routes.admin_user_path(merchantAccount.user_id)}>{merchantAccount.user_id}</Link>
          ) : (
            "none"
          )}
        </dd>

        <dt>Country</dt>
        <dd>
          {merchantAccount.country_name} ({merchantAccount.country})
        </dd>

        <dt>Currency</dt>
        <dd>{merchantAccount.currency.toUpperCase()}</dd>

        <dt>Active</dt>
        <dd>
          <BooleanIcon value={!!merchantAccount.deleted_at} />
        </dd>

        <dt>Funds are held by</dt>
        <dd>{capitalize(merchantAccount.holder_of_funds)}</dd>

        <dt>Charge Processor</dt>
        <dd>
          {capitalize(merchantAccount.charge_processor_id)}{" "}
          {merchantAccount.charge_processor_merchant_id ? (
            <a href={merchantAccount.stripe_account_url} target="_blank" rel="noopener noreferrer">
              {merchantAccount.charge_processor_merchant_id}
            </a>
          ) : null}
        </dd>

        <dt>{capitalize(merchantAccount.charge_processor_id)} Alive</dt>
        <dd>
          <BooleanIcon value={!!merchantAccount.charge_processor_alive_at} />{" "}
          <DateTimeWithRelativeTooltip date={merchantAccount.charge_processor_alive_at} utc />
        </dd>

        <dt>{capitalize(merchantAccount.charge_processor_id)} Verified</dt>
        <dd>
          <BooleanIcon value={!!merchantAccount.charge_processor_verified_at} />{" "}
          <DateTimeWithRelativeTooltip date={merchantAccount.charge_processor_verified_at} utc />
        </dd>

        <dt>{capitalize(merchantAccount.charge_processor_id)} Deleted</dt>
        <dd>
          <BooleanIcon value={!!merchantAccount.charge_processor_deleted_at} />{" "}
          <DateTimeWithRelativeTooltip date={merchantAccount.charge_processor_deleted_at} utc />
        </dd>
      </dl>
    </div>

    <hr />
    <div className="paragraphs">
      <h3>Charge Processor live attributes</h3>
      {Object.keys(merchantAccount.live_attributes).length > 0 ? (
        <dl>
          {Object.entries(merchantAccount.live_attributes).map(([key, value]) => (
            <React.Fragment key={key}>
              <dt>{key}</dt>
              <dd>
                <code>{JSON.stringify(value)}</code>
              </dd>
            </React.Fragment>
          ))}
        </dl>
      ) : (
        <div role="alert" className="info">
          Charge Processor Merchant information is missing.
        </div>
      )}
    </div>

    <hr />
    <div>
      <dl>
        <dt>Updated</dt>
        <dd>
          <DateTimeWithRelativeTooltip date={merchantAccount.updated_at} utc />
        </dd>
      </dl>

      <dl>
        <dt>Deleted</dt>
        <dd>
          <DateTimeWithRelativeTooltip date={merchantAccount.deleted_at} utc placeholder={<NoIcon />} />
        </dd>
      </dl>
    </div>
  </div>
);

export default AdminMerchantAccount;
