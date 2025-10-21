import { Link } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import BlockedUserTooltip from "$app/components/Admin/Users/BlockedUserTooltip";
import AdminUserStats from "$app/components/Admin/Users/Stats";
import type { User } from "$app/components/Admin/Users/User";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { WithTooltip } from "$app/components/WithTooltip";

type HeaderProps = {
  user: User;
  is_affiliate_user?: boolean;
  url: string;
};

const Header = ({ user, is_affiliate_user = false, url }: HeaderProps) => {
  const displayName = user.name || `User ${user.username}`;
  const adminUserUrl = is_affiliate_user ? Routes.admin_affiliate_url(user.id) : Routes.admin_user_url(user.id);

  return (
    <div className="paragraphs">
      <div className="flex items-center gap-4">
        <img
          src={user.avatar_url}
          className="user-avatar"
          style={{ width: "var(--form-element-height)" }}
          alt={user.name}
        />
        <div className="grid gap-2">
          <h2>
            <Link href={adminUserUrl} className={classNames({ active: url === adminUserUrl })}>
              {displayName}
            </Link>
          </h2>
          <ul className="inline">
            <li>
              <DateTimeWithRelativeTooltip date={user.created_at} />
            </li>
            {user.username ? (
              <li>
                <Link href={user.subdomain_with_protocol} target="_blank" rel="noopener noreferrer nofollow">
                  {user.username}
                </Link>
              </li>
            ) : null}
            {user.form_email ? (
              <li className="space-x-1">
                <span>Email: {user.form_email}</span>
                <CopyToClipboard tooltipPosition="bottom" copyTooltip="Copy email" text={user.form_email}>
                  <Icon name="outline-duplicate" />
                </CopyToClipboard>
                <BlockedUserTooltip user={user} position="bottom" />
              </li>
            ) : null}
            {user.support_email ? (
              <li className="space-x-1">
                <span>Support email: {user.support_email}</span>
                <CopyToClipboard tooltipPosition="bottom" copyTooltip="Copy support email" text={user.support_email}>
                  <Icon name="outline-duplicate" />
                </CopyToClipboard>
              </li>
            ) : null}
            {user.custom_fee_per_thousand ? (
              <li>
                <WithTooltip
                  tip="Custom fee that will be charged on all their new direct (non-discover) sales"
                  position="bottom"
                >
                  <span>Custom fee: {user.custom_fee_per_thousand / 10}%</span>
                </WithTooltip>
              </li>
            ) : null}
            <li>
              <Link href={Routes.admin_user_payouts_url(user)}>Payouts</Link>
            </li>
          </ul>

          <AdminUserStats user_id={user.id} />
        </div>
      </div>
    </div>
  );
};

export default Header;
