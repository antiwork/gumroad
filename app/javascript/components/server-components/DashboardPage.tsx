import * as React from "react";
import { createCast } from "ts-safe-cast";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { register } from "$app/utils/serverComponentUtil";

import { ActivityFeed, ActivityItem } from "$app/components/ActivityFeed";
import { NavigationButton, Button } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { CustomizeProfileIcon } from "$app/components/icons/getting-started/CustomizeProfileIcon";
import { EmailBlastIcon } from "$app/components/icons/getting-started/EmailBlastIcon";
import { FirstFollowerIcon } from "$app/components/icons/getting-started/FirstFollowerIcon";
import { FirstPayoutIcon } from "$app/components/icons/getting-started/FirstPayoutIcon";
import { FirstProductIcon } from "$app/components/icons/getting-started/FirstProductIcon";
import { FirstSaleIcon } from "$app/components/icons/getting-started/FirstSaleIcon";
import { MakeAccountIcon } from "$app/components/icons/getting-started/MakeAccountIcon";
import { SmallBetsIcon } from "$app/components/icons/getting-started/SmallBetsIcon";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Stats } from "$app/components/Stats";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useClientSortingTableDriver } from "$app/components/useSortingTableDriver";

import placeholderImage from "$assets/images/placeholders/dashboard.png";

type ProductRow = {
  id: string;
  name: string;
  thumbnail: string | null;
  sales: number;
  revenue: number;
  visits: number;
  today: number;
  last_7: number;
  last_30: number;
  show_1099_download_notice?: boolean;
};

interface GettingStartedIconProps extends React.SVGProps<SVGSVGElement> {
  isChecked: boolean;
}

type Props = {
  name: string;
  has_sale: boolean;
  getting_started_stats: {
    customized_profile: boolean;
    first_follower: boolean;
    first_product: boolean;
    first_sale: boolean;
    first_payout: boolean;
    first_email: boolean;
    first_small_bets: boolean;
  };
  sales: ProductRow[];
  balances: {
    balance: string;
    last_seven_days_sales_total: string;
    last_28_days_sales_total: string;
    total: string;
  };
  activity_items: ActivityItem[];
  stripe_verification_message?: string | null;
  show_1099_download_notice?: boolean;
};
type TableProps = { sales: ProductRow[] };

type RadioItemProps = {
  name: string;
  checked: boolean;
  link: string;
  IconComponent?: React.ComponentType<GettingStartedIconProps>;
  description?: string;
};

const Greeter = () => (
  <div className="placeholder">
    <figure>
      <img src={placeholderImage} />
    </figure>
    <h2>We're here to help you get paid for your work.</h2>
    <NavigationButton href={Routes.new_product_path()} color="accent">
      Create your first product
    </NavigationButton>
    <a href="#" data-helper-prompt="How can I create my first product?">
      Learn more about creating products.
    </a>
  </div>
);

const RadioItem = ({ name, checked, link, IconComponent, description }: RadioItemProps) => {
  const handleClick = () => {
    if (!checked && link) {
      window.location.href = link;
    }
  };

  return (
    <Button
      role="radio"
      aria-checked={checked}
      onClick={handleClick}
      color="filled"
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        textAlign: "center",
        gap: "var(--spacer-1)",
        padding: "var(--spacer-6) var(--spacer-4)",
        position: "relative",
      }}
    >
      <Icon
        name={checked ? "solid-check-circle" : "circle"}
        style={{
          position: "absolute",
          top: "var(--spacer-2)",
          right: "var(--spacer-2)",
          color: checked ? "rgb(var(--success))" : "rgb(var(--gray-400))",
        }}
      />
      {IconComponent ? (
        <div style={{ marginBottom: "var(--spacer-2)" }}>
          <IconComponent isChecked={checked} width="80" height="80" />
        </div>
      ) : (
        <div style={{ width: 80, height: 80, border: "1px dashed gray", marginBottom: "var(--spacer-2)" }} />
      )}
      <div className="text-lg font-semibold leading-tight">{name}</div>
      {description ? <p style={{ fontSize: "var(--font-size-small)", opacity: 0.8 }}>{description}</p> : null}
    </Button>
  );
};

const formatPrice = (cents: number) =>
  formatPriceCentsWithCurrencySymbol("usd", cents, { symbolFormat: "short", noCentsIfWhole: true });

const ProductsTable = ({ sales }: TableProps) => {
  const { items, thProps } = useClientSortingTableDriver(sales);
  const appDomain = useAppDomain();

  const { locale } = useUserAgentInfo();

  if (!sales.length) return null;

  if (sales.every((b) => b.sales === 0)) {
    return (
      <div style={{ display: "grid", gap: "var(--spacer-4)" }}>
        <h2>Best selling</h2>
        <div className="placeholder">
          <p>
            You haven't made any sales yet. Learn how to{" "}
            <a href="#" data-helper-prompt="How can I build a following?">
              build a following
            </a>{" "}
            and{" "}
            <a href="#" data-helper-prompt="How can I sell on Gumroad Discover?">
              sell on Gumroad Discover
            </a>
          </p>
        </div>
      </div>
    );
  }

  return (
    <table>
      <caption>Best selling</caption>
      <thead>
        <tr>
          <th colSpan={2} {...thProps("name")}>
            Products
          </th>
          <th {...thProps("sales")}>Sales</th>
          <th {...thProps("revenue")}>Revenue</th>
          <th {...thProps("visits")}>Visits</th>
          <th {...thProps("today")}>Today</th>
          <th className="text-singleline" {...thProps("last_7")}>
            Last 7 days
          </th>
          <th className="text-singleline" {...thProps("last_30")}>
            Last 30 days
          </th>
        </tr>
      </thead>
      <tbody>
        {items.map(({ id, name, thumbnail, today, last_7, last_30, sales, visits, revenue }) => (
          <tr key={id}>
            <td className="icon-cell">
              <a href={Routes.edit_link_url({ id }, { host: appDomain })}>
                {thumbnail ? <img alt={name} src={thumbnail} /> : <Icon name="card-image-fill" />}
              </a>
            </td>
            <td data-label="Products">
              <a href={Routes.edit_link_url({ id }, { host: appDomain })} style={{ wordWrap: "break-word" }}>
                {name}
              </a>
            </td>
            <td data-label="Sales">{sales.toLocaleString(locale)}</td>
            <td data-label="Revenue">{formatPrice(revenue)}</td>
            <td data-label="Visits">{visits.toLocaleString(locale)}</td>
            <td data-label="Today">{formatPrice(today)}</td>
            <td data-label="Last 7 days">{formatPrice(last_7)}</td>
            <td data-label="Last 30 days">{formatPrice(last_30)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
};

export const DashboardPage = ({
  name,
  has_sale,
  getting_started_stats,
  sales,
  activity_items,
  balances,
  stripe_verification_message,
  show_1099_download_notice,
}: Props) => {
  const loggedInUser = useLoggedInUser();

  return (
    <main>
      <header>
        <h1>
          {name ? `Hey, ${name}! ` : null}
          {has_sale ? "Welcome back to Gumroad." : "Welcome to Gumroad."}
        </h1>
      </header>
      <div className="main-app-content" style={{ display: "grid", gap: "var(--spacer-7)" }}>
        {stripe_verification_message ? (
          <div role="alert" className="warning">
            <div>
              {stripe_verification_message} <a href={Routes.settings_payments_path()}>Update</a>
            </div>
          </div>
        ) : null}
        {show_1099_download_notice ? (
          <div role="alert" className="info">
            <div>
              Your 1099 tax form for {new Date().getFullYear() - 1} is ready!{" "}
              <a href={Routes.dashboard_download_tax_form_path()}>Click here to download</a>.
            </div>
          </div>
        ) : null}

        {loggedInUser?.policies.settings_payments_user.show
          ? Object.values(getting_started_stats).some((v) => !v) && (
              <div style={{ display: "grid", gap: "var(--spacer-4)" }}>
                <h2>Getting started</h2>
                <div
                  style={{
                    display: "grid",
                    gridTemplateColumns: "repeat(auto-fit, minmax(15rem, 1fr))",
                    gap: "var(--spacer-4)",
                  }}
                >
                  <RadioItem
                    name="Welcome aboard"
                    checked
                    link=""
                    IconComponent={MakeAccountIcon}
                    description="Make a Gumroad account."
                  />
                  <RadioItem
                    name="Make an impression"
                    checked={getting_started_stats.customized_profile}
                    link={Routes.settings_profile_path()}
                    IconComponent={CustomizeProfileIcon}
                    description="Customize your profile."
                  />
                  <RadioItem
                    name="Showtime"
                    checked={getting_started_stats.first_product}
                    link={Routes.new_product_path()}
                    IconComponent={FirstProductIcon}
                    description="Create your first product."
                  />
                  <RadioItem
                    name="Build your tribe"
                    checked={getting_started_stats.first_follower}
                    link={Routes.followers_path()}
                    IconComponent={FirstFollowerIcon}
                    description="Get your first follower."
                  />
                  <RadioItem
                    name="Cha-ching"
                    checked={getting_started_stats.first_sale}
                    link={Routes.sales_dashboard_path()}
                    IconComponent={FirstSaleIcon}
                    description="Make your first sale."
                  />
                  <RadioItem
                    name="Money inbound"
                    checked={getting_started_stats.first_payout}
                    link={Routes.settings_payments_path()}
                    IconComponent={FirstPayoutIcon}
                    description="Get your first pay out."
                  />
                  <RadioItem
                    name="Making waves"
                    checked={getting_started_stats.first_email}
                    link={Routes.posts_path()}
                    IconComponent={EmailBlastIcon}
                    description="Send out your first email blast."
                  />
                  <RadioItem
                    name="Smart move"
                    checked={getting_started_stats.first_small_bets}
                    link="https://dvassallo.gumroad.com/l/small-bets?layout=profile"
                    IconComponent={SmallBetsIcon}
                    description="Sign up for Small Bets."
                  />
                </div>
              </div>
            )
          : null}

        {!getting_started_stats.first_product && loggedInUser?.policies.product.create ? <Greeter /> : null}

        {!getting_started_stats.first_product && loggedInUser?.policies.product.create ? null : (
          <ProductsTable sales={sales} />
        )}

        <div className="grid gap-4">
          <h2>Activity</h2>
          {!getting_started_stats.first_product && loggedInUser?.policies.product.create ? null : (
            <div className="stats-grid">
              <Stats
                title="Balance"
                description="Your current balance available for payout"
                value={balances.balance}
                url={Routes.balance_path()}
              />
              <Stats
                title="Last 7 days"
                description="Your total sales in the last 7 days"
                value={balances.last_seven_days_sales_total}
                url={Routes.sales_dashboard_path()}
              />
              <Stats
                title="Last 28 days"
                description="Your total sales in the last 28 days"
                value={balances.last_28_days_sales_total}
                url={Routes.sales_dashboard_path()}
              />
              <Stats
                title="Total earnings"
                description="Your all-time net earnings from all products, excluding refunds and chargebacks"
                value={balances.total}
                url={Routes.dashboard_total_revenue_path()}
              />
            </div>
          )}
          <ActivityFeed items={activity_items} />
        </div>
      </div>
    </main>
  );
};

export default register({ component: DashboardPage, propParser: createCast() });
