import * as React from "react";
import { createCast } from "ts-safe-cast";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { register } from "$app/utils/serverComponentUtil";

import { ActivityFeed, ActivityItem } from "$app/components/ActivityFeed";
import { NavigationButton } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
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
};

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
  show_1099_download_notice: boolean;
};
type TableProps = { sales: ProductRow[] };

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

const RadioItem = ({ name, checked, link }: { name: string; checked: boolean; link: string }) => (
  <div>
    <div style={{ display: "flex", gap: "var(--spacer-3)" }}>
      {checked ? (
        <>
          <Icon name="solid-check-circle" style={{ backgroundColor: "rgb(var(--success))" }} />
          <s>{name}</s>
        </>
      ) : (
        <>
          <Icon name="circle" />
          <a href={link}>{name}</a>
        </>
      )}
    </div>
  </div>
);

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
        {!getting_started_stats.first_product && loggedInUser?.policies.product.create ? <Greeter /> : null}
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

        {loggedInUser?.policies.settings_payments_user.show
          ? Object.values(getting_started_stats).some((v) => !v) && (
              <div style={{ display: "grid", gap: "var(--spacer-4)" }}>
                <h2>Getting started</h2>
                <div className="stack two-columns">
                  <RadioItem
                    name="Customize your profile"
                    checked={getting_started_stats.customized_profile}
                    link={Routes.settings_profile_path()}
                  />
                  <RadioItem
                    name="Create your first product"
                    checked={getting_started_stats.first_product}
                    link={Routes.new_product_path()}
                  />
                  <RadioItem
                    name="Get your first follower"
                    checked={getting_started_stats.first_follower}
                    link={Routes.followers_path()}
                  />
                  <RadioItem
                    name="Make your first sale"
                    checked={getting_started_stats.first_sale}
                    link={Routes.sales_dashboard_path()}
                  />
                  <RadioItem
                    name="Get your first pay out"
                    checked={getting_started_stats.first_payout}
                    link={Routes.settings_payments_path()}
                  />
                  <RadioItem
                    name="Send out your first email blast"
                    checked={getting_started_stats.first_email}
                    link={Routes.posts_path()}
                  />
                </div>
              </div>
            )
          : null}

        <ProductsTable sales={sales} />

        <div style={{ display: "grid", gap: "var(--spacer-4)" }}>
          <h2>Activity</h2>
          <ActivityFeed items={activity_items} />
        </div>
      </div>
    </main>
  );
};

export default register({ component: DashboardPage, propParser: createCast() });
