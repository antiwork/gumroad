import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Card, CardContent } from "$app/components/ui/Card";
import { Placeholder } from "$app/components/ui/Placeholder";
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
      Đơn hàng mới của <a href={Routes.short_link_path({ id: product_unique_permalink })}>{product_name}</a> với giá{" "}
      {formatPriceCentsWithCurrencySymbol("usd", price_cents, { symbolFormat: "short", noCentsIfWhole: true })}
    </span>
  </>
);

const Follow = ({ details: { email, name } }: { details: FollowItemDetails }) => (
  <>
    <Icon name="person-circle-fill" />
    <span> Người theo dõi mới {name || email} đã tham gia</span>
  </>
);

const FollowRemoved = ({ details: { email, name } }: { details: FollowItemDetails }) => (
  <>
    <Icon name="person-circle-fill" />
    <span> Người theo dõi {name || email} đã hủy theo dõi</span>
  </>
);

export const ActivityFeed = ({ items }: { items: ActivityItem[] }) => {
  const loggedInUser = useLoggedInUser();
  const userAgentInfo = useUserAgentInfo();

  if (!items.length) {
    return (
      <Placeholder>
        <p>
          Người theo dõi và doanh số sẽ hiển thị ở đây khi có cập nhật mới.
          {loggedInUser?.policies.product.create ? (
            <span>
              {" "}
              Bây giờ, hãy <a href={Routes.products_path()}>tạo sản phẩm</a> hoặc{" "}
              <a href={Routes.settings_profile_path()}>tùy chỉnh hồ sơ của bạn</a>
            </span>
          ) : null}
        </p>
      </Placeholder>
    );
  }

  return (
    <Card>
      {items.map(({ type, timestamp, details }, i) => (
        <CardContent key={i}>
          <span className="flex grow gap-3">
            {type === "new_sale" && <Sale details={details} />}
            {type === "follower_added" && <Follow details={details} />}
            {type === "follower_removed" && <FollowRemoved details={details} />}
          </span>
          <span className="text-muted" suppressHydrationWarning>
            {new Date(timestamp).toLocaleString(userAgentInfo.locale, { dateStyle: "medium", timeStyle: "short" })}
          </span>
        </CardContent>
      ))}
    </Card>
  );
};
