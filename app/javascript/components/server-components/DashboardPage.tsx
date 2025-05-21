import cx from "classnames";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";
import { register } from "$app/utils/serverComponentUtil";

import { ActivityFeed, ActivityItem } from "$app/components/ActivityFeed";
import { NavigationButton } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { CustomizeProfileIcon } from "$app/components/icons/getting-started/CustomizeProfileIcon";
import { EmailBlastIcon } from "$app/components/icons/getting-started/EmailBlastIcon";
import { FirstFollowerIcon } from "$app/components/icons/getting-started/FirstFollowerIcon";
import { FirstPayoutIcon } from "$app/components/icons/getting-started/FirstPayoutIcon";
import { FirstProductIcon } from "$app/components/icons/getting-started/FirstProductIcon";
import { FirstSaleIcon } from "$app/components/icons/getting-started/FirstSaleIcon";
import { GettingStartedIconProps } from "$app/components/icons/getting-started/GettingStartedIconProps";
import { MakeAccountIcon } from "$app/components/icons/getting-started/MakeAccountIcon";
import { SmallBetsIcon } from "$app/components/icons/getting-started/SmallBetsIcon";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Stats } from "$app/components/Stats";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";
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
    purchased_small_bets: boolean;
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

type GettingStartedItemType = {
  key: string;
  name: string;
  getChecked: (stats: Props["getting_started_stats"]) => boolean;
  link: string;
  IconComponent: React.ComponentType<GettingStartedIconProps>;
  description: string;
};

type GettingStartedItemProps = {
  name: string;
  checked: boolean;
  minimized: boolean;
  link: string;
  IconComponent: React.ComponentType<GettingStartedIconProps>;
  description: string;
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

const GettingStartedItem = ({
  name,
  checked,
  link,
  IconComponent,
  description,
  minimized,
}: GettingStartedItemProps) => {
  const commonClasses = "relative";

  const iconName = checked ? "solid-check-circle" : "circle";
  const iconClasses = checked ? "text-green" : "text-dark-gray";

  const content = minimized ? (
    <div className="flex w-full items-center gap-2">
      <IconComponent isChecked={checked} width={36} height={36} className="flex-none" />
      <span className="mb-1 flex-1 font-semibold leading-tight">{name}</span>
      <Icon name={iconName} className={cx("flex-none", iconClasses)} />
    </div>
  ) : (
    <div className="my-3 flex flex-col items-center gap-1">
      <IconComponent isChecked={checked} width={60} height={60} />
      <span className="font-semibold leading-tight">{name}</span>
      <Icon name={iconName} className={cx("absolute right-2 top-2", iconClasses)} />
      <p className="text-sm opacity-80">{description}</p>
    </div>
  );

  if (checked) {
    return <div className={cx(commonClasses, "button filled !cursor-default")}>{content}</div>;
  }

  return (
    <NavigationButton color="filled" href={link} className={commonClasses}>
      {content}
    </NavigationButton>
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

const GETTING_STARTED_MINIMIZED_KEY = "dashboardGettingStartedMinimized";

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
  const [gettingStartedMinimized, setGettingStartedMinimized] = React.useState<boolean>(false);

  useRunOnce(() => {
    setGettingStartedMinimized(window.localStorage.getItem(GETTING_STARTED_MINIMIZED_KEY) === "true");
  });

  const toggleGettingStarted = () => {
    const newState = !gettingStartedMinimized;
    window.localStorage.setItem(GETTING_STARTED_MINIMIZED_KEY, JSON.stringify(newState));
    setGettingStartedMinimized(newState);
  };

  const gettingStartedItems: GettingStartedItemType[] = [
    {
      key: "welcome",
      name: "Welcome aboard",
      getChecked: () => true,
      link: Routes.dashboard_path(),
      IconComponent: MakeAccountIcon,
      description: "Make a Gumroad account.",
    },
    {
      key: "profile",
      name: "Make an impression",
      getChecked: (stats) => stats.customized_profile,
      link: Routes.settings_profile_path(),
      IconComponent: CustomizeProfileIcon,
      description: "Customize your profile.",
    },
    {
      key: "product",
      name: "Showtime",
      getChecked: (stats) => stats.first_product,
      link: Routes.new_product_path(),
      IconComponent: FirstProductIcon,
      description: "Create your first product.",
    },
    {
      key: "follower",
      name: "Build your tribe",
      getChecked: (stats) => stats.first_follower,
      link: Routes.followers_path(),
      IconComponent: FirstFollowerIcon,
      description: "Get your first follower.",
    },
    {
      key: "sale",
      name: "Cha-ching",
      getChecked: (stats) => stats.first_sale,
      link: Routes.sales_dashboard_path(),
      IconComponent: FirstSaleIcon,
      description: "Make your first sale.",
    },
    {
      key: "payout",
      name: "Money inbound",
      getChecked: (stats) => stats.first_payout,
      link: Routes.settings_payments_path(),
      IconComponent: FirstPayoutIcon,
      description: "Get your first pay out.",
    },
    {
      key: "email",
      name: "Making waves",
      getChecked: (stats) => stats.first_email,
      link: Routes.posts_path(),
      IconComponent: EmailBlastIcon,
      description: "Send out your first email blast.",
    },
    {
      key: "small_bets",
      name: "Smart move",
      getChecked: (stats) => stats.purchased_small_bets,
      link: "https://dvassallo.gumroad.com/l/small-bets?layout=profile",
      IconComponent: SmallBetsIcon,
      description: "Sign up for Small Bets.",
    },
  ];

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
              <div className="override grid gap-4">
                <div className="flex items-center justify-between">
                  <h2>Getting started</h2>
                  <a
                    href="#"
                    onClick={(e) => {
                      e.preventDefault();
                      toggleGettingStarted();
                    }}
                    aria-label={gettingStartedMinimized ? "Expand getting started" : "Minimize getting started"}
                    style={{ display: "flex", alignItems: "center", gap: "var(--spacer-1)" }}
                  >
                    <span>{gettingStartedMinimized ? "Show more" : "Show less"}</span>
                    <Icon
                      name={gettingStartedMinimized ? "arrows-expand" : "arrows-collapse"}
                      style={{ width: "20px", height: "20px" }}
                    />
                  </a>
                </div>
                <div className="override grid w-full grid-cols-[repeat(auto-fit,minmax(15rem,1fr))] gap-4">
                  {gettingStartedItems.map((item) => (
                    <GettingStartedItem
                      key={item.key}
                      name={item.name}
                      checked={item.getChecked(getting_started_stats)}
                      link={item.link}
                      IconComponent={item.IconComponent}
                      description={item.description}
                      minimized={gettingStartedMinimized}
                    />
                  ))}
                </div>
              </div>
            )
          : null}

        {!getting_started_stats.first_product && loggedInUser?.policies.product.create ? <Greeter /> : null}

        <ProductsTable sales={sales} />

        <div className="grid gap-4">
          <h2>Activity</h2>

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

          <ActivityFeed items={activity_items} />
        </div>
      </div>
    </main>
  );
};

export default register({ component: DashboardPage, propParser: createCast() });
