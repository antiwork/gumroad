import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { useUserAgentInfo } from "$app/components/UserAgent";

type SaleItemDetails = {
  price_cents: number;
  email: string;
  full_name: string | null;
  product_name: string;
  product_unique_permalink: string;
};

type FollowItemDetails = { email: string; name: string | null };

export type ActivityItem =
  | { type: "new_sale"; timestamp: string; details: SaleItemDetails }
  | { type: "follower_added" | "follower_removed"; timestamp: string; details: FollowItemDetails };

const Sale = ({ details: { price_cents, product_name, product_unique_permalink } }: { details: SaleItemDetails }) => (
  <>
    <Icon name="outline-currency-dollar" className="text-green" />
    <span>
      New sale of <a href={Routes.short_link_path({ id: product_unique_permalink })}>{product_name}</a> for{" "}
      {formatPriceCentsWithCurrencySymbol("usd", price_cents, { symbolFormat: "short", noCentsIfWhole: true })}
    </span>
  </>
);

const Follow = ({ details: { email, name } }: { details: FollowItemDetails }) => (
  <>
    <Icon name="person-circle-fill" />
    <span> New follower {name || email} added</span>
  </>
);

const FollowRemoved = ({ details: { email, name } }: { details: FollowItemDetails }) => (
  <>
    <Icon name="person-circle-fill" />
    <span> Follower {name || email} removed</span>
  </>
);

export const ActivityFeed = ({ items }: { items: ActivityItem[] }) => {
  const loggedInUser = useLoggedInUser();
  const userAgentInfo = useUserAgentInfo();

  if (!items.length) {
    return (
      <div className="placeholder">
        <p>
          Followers and sales will show up here as they come in.
          {loggedInUser?.policies.product.create ? (
            <span>
              {" "}
              For now, <a href={Routes.products_path()}>create a product</a> or{" "}
              <a href={Routes.settings_profile_path()}>customize your profile</a>
            </span>
          ) : null}
        </p>
      </div>
    );
  }

  return (
    <div className="stack">
      {items.map(({ type, timestamp, details }, i) => (
        <div key={i}>
          <span className="flex gap-3">
            {type === "new_sale" && <Sale details={details} />}
            {type === "follower_added" && <Follow details={details} />}
            {type === "follower_removed" && <FollowRemoved details={details} />}
          </span>
          <span className="text-muted" suppressHydrationWarning>
            {new Date(timestamp).toLocaleString(userAgentInfo.locale, { dateStyle: "medium", timeStyle: "short" })}
          </span>
        </div>
      ))}
    </div>
  );
};
