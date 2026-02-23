import { Link } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { formatPriceCentsWithCurrencySymbol } from "$app/utils/currency";

import { ActivityFeed, ActivityItem } from "$app/components/ActivityFeed";
import { Button, NavigationButton } from "$app/components/Button";
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
import { ProductIconCell } from "$app/components/ProductsPage/ProductIconCell";
import { DownloadTaxFormsPopover } from "$app/components/server-components/DashboardPage/DownloadTaxFormsPopover";
import { Stats } from "$app/components/Stats";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
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
};

export type DashboardPageProps = {
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
  tax_forms: Record<number, string>;
  show_1099_download_notice: boolean;
  tax_center_enabled: boolean;
};
type TableProps = { sales: ProductRow[] };

type GettingStartedItemType = {
  name: string;
  getCompleted: (stats: DashboardPageProps["getting_started_stats"]) => boolean;
  link: string;
  IconComponent: React.ComponentType<GettingStartedIconProps>;
  description: string;
};

const GETTING_STARTED_ITEMS: GettingStartedItemType[] = [
  {
    name: "Welcome aboard",
    getCompleted: () => true,
    link: Routes.dashboard_path(),
    IconComponent: MakeAccountIcon,
    description: "Make a Gumroad account.",
  },
  {
    name: "Make an impression",
    getCompleted: (stats) => stats.customized_profile,
    link: Routes.settings_profile_path(),
    IconComponent: CustomizeProfileIcon,
    description: "Customize your profile.",
  },
  {
    name: "Showtime",
    getCompleted: (stats) => stats.first_product,
    link: Routes.new_product_path(),
    IconComponent: FirstProductIcon,
    description: "Create your first product.",
  },
  {
    name: "Build your tribe",
    getCompleted: (stats) => stats.first_follower,
    link: Routes.followers_path(),
    IconComponent: FirstFollowerIcon,
    description: "Get your first follower.",
  },
  {
    name: "Cha-ching",
    getCompleted: (stats) => stats.first_sale,
    link: Routes.sales_dashboard_path(),
    IconComponent: FirstSaleIcon,
    description: "Make your first sale.",
  },
  {
    name: "Money inbound",
    getCompleted: (stats) => stats.first_payout,
    link: Routes.settings_payments_path(),
    IconComponent: FirstPayoutIcon,
    description: "Get your first pay out.",
  },
  {
    name: "Making waves",
    getCompleted: (stats) => stats.first_email,
    link: Routes.posts_path(),
    IconComponent: EmailBlastIcon,
    description: "Send out your first email blast.",
  },
  {
    name: "Smart move",
    getCompleted: (stats) => stats.purchased_small_bets,
    link: Routes.small_bets_url(),
    IconComponent: SmallBetsIcon,
    description: "Sign up for Small Bets.",
  },
];

type GettingStartedItemProps = {
  name: string;
  completed: boolean;
  minimized: boolean;
  link: string;
  IconComponent: React.ComponentType<GettingStartedIconProps>;
  description: string;
};

const Greeter = () => (
  <Placeholder>
    <PlaceholderImage src={placeholderImage} />
    <h2>We're here to help you get paid for your work.</h2>
    <NavigationButton href={Routes.new_product_path()} color="accent">
      Create your first product
    </NavigationButton>
    <a href="/help/article/149-adding-a-product" target="_blank" rel="noreferrer">
      Learn more about creating products
    </a>
  </Placeholder>
);

const GettingStartedItem = ({
  name,
  completed,
  link,
  IconComponent,
  description,
  minimized,
}: GettingStartedItemProps) => {
  const commonClasses = "relative";

  const iconName = completed ? "solid-check-circle" : "circle";
  const iconClasses = completed ? "text-green" : "text-dark-gray";

  const content = minimized ? (
    <div className="flex w-full items-center gap-2">
      <IconComponent isChecked={completed} width={36} height={36} className="flex-none" />
      <span className="mb-1 flex-1 text-left leading-tight font-semibold">{name}</span>
      <Icon name={iconName} className={cx("flex-none", iconClasses)} />
    </div>
  ) : (
    <div className="my-3 flex flex-col items-center gap-1">
      <IconComponent isChecked={completed} width={60} height={60} />
      <span className="leading-tight font-semibold">{name}</span>
      <Icon name={iconName} className={cx("absolute top-2 right-2", iconClasses)} />
      <p className="text-sm opacity-80">{description}</p>
    </div>
  );

  if (completed) {
    return (
      <Button color="filled" className={cx(commonClasses, "cursor-default!")} data-status="completed">
        {content}
      </Button>
    );
  }

  return (
    <NavigationButton color="filled" href={link} className={commonClasses} data-status="pending">
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
      <div className="grid gap-4">
        <h2>Best selling</h2>
        <Placeholder>
          <p>
            You haven't made any sales yet. Learn how to{" "}
            <a href="/help/article/170-audience" target="_blank" rel="noreferrer">
              build a following
            </a>{" "}
            and{" "}
            <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
              sell on Gumroad Discover
            </a>
          </p>
        </Placeholder>
      </div>
    );
  }

  return (
    <Table>
      <TableCaption>Best selling</TableCaption>
      <TableHeader>
        <TableRow>
          <TableHead colSpan={2} {...thProps("name")}>
            Products
          </TableHead>
          <TableHead {...thProps("sales")}>Sales</TableHead>
          <TableHead {...thProps("revenue")}>Revenue</TableHead>
          <TableHead {...thProps("visits")}>Visits</TableHead>
          <TableHead {...thProps("today")}>Today</TableHead>
          <TableHead className="text-singleline" {...thProps("last_7")}>
            Last 7 days
          </TableHead>
          <TableHead className="text-singleline" {...thProps("last_30")}>
            Last 30 days
          </TableHead>
        </TableRow>
      </TableHeader>
      <TableBody>
        {items.map(({ id, name, thumbnail, today, last_7, last_30, sales, visits, revenue }) => (
          <TableRow key={id}>
            <ProductIconCell href={Routes.edit_link_url({ id }, { host: appDomain })} thumbnail={thumbnail} />
            <TableCell label="Products">
              <a href={Routes.edit_link_url({ id }, { host: appDomain })} className="line-clamp-2" title={name}>
                {name}
              </a>
            </TableCell>
            <TableCell label="Sales" title={sales.toLocaleString(locale)} className="whitespace-nowrap">
              {sales.toLocaleString(locale, { notation: "compact" })}
            </TableCell>
            <TableCell label="Revenue" title={formatPrice(revenue)} className="whitespace-nowrap">
              {formatPrice(revenue)}
            </TableCell>
            <TableCell label="Visits" title={visits.toLocaleString(locale)} className="whitespace-nowrap">
              {visits.toLocaleString(locale, { notation: "compact" })}
            </TableCell>
            <TableCell label="Today" className="whitespace-nowrap">
              {formatPrice(today)}
            </TableCell>
            <TableCell label="Last 7 days" className="whitespace-nowrap">
              {formatPrice(last_7)}
            </TableCell>
            <TableCell label="Last 30 days" className="whitespace-nowrap">
              {formatPrice(last_30)}
            </TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
};

const GETTING_STARTED_MINIMIZED_KEY = "dashboardGettingStartedMinimized";

export const DashboardPage = ({
  getting_started_stats,
  sales,
  activity_items,
  balances,
  stripe_verification_message,
  tax_forms,
  show_1099_download_notice,
  tax_center_enabled,
}: DashboardPageProps) => {
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

  return (
    <div>
      <PageHeader
        title="Dashboard"
        actions={
          tax_center_enabled
            ? null
            : Object.keys(tax_forms).length > 0 && <DownloadTaxFormsPopover taxForms={tax_forms} />
        }
        className="border-b-0 sm:border-b"
      />
      {stripe_verification_message ? (
        <Alert variant="warning">
          {stripe_verification_message} <a href={Routes.settings_payments_path()}>Update</a>
        </Alert>
      ) : null}
      {show_1099_download_notice ? (
        <Alert variant="info">
          Your 1099 tax form for {new Date().getFullYear() - 1} is ready!{" "}
          {tax_center_enabled ? (
            <Link href={Routes.tax_center_path({ year: new Date().getFullYear() - 1 })}>Click here to download</Link>
          ) : (
            <a href={Routes.dashboard_download_tax_form_path()}>Click here to download</a>
          )}
          .
        </Alert>
      ) : null}

      {loggedInUser?.policies.settings_payments_user.show
        ? Object.values(getting_started_stats).some((v) => !v) && (
            <div className="grid gap-4 p-4 md:p-8">
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
              <div className="grid w-full grid-cols-1 gap-4 min-[2000px]:grid-cols-8 sm:grid-cols-2 xl:grid-cols-4">
                {GETTING_STARTED_ITEMS.map((item) => (
                  <GettingStartedItem
                    key={item.name}
                    name={item.name}
                    completed={item.getCompleted(getting_started_stats)}
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

      {!getting_started_stats.first_product && loggedInUser?.policies.product.create ? (
        <div className="p-4 md:p-8">
          <Greeter />
        </div>
      ) : null}

      {sales.length > 0 ? (
        <div className="p-4 md:p-8">
          <ProductsTable sales={sales} />
        </div>
      ) : null}

      <div className="grid gap-4 p-4 md:p-8">
        <h2>Activity</h2>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Stats title="Balance" description="Your current balance available for payout" value={balances.balance} />
          <Stats
            title="Last 7 days"
            description="Your total sales in the last 7 days"
            value={balances.last_seven_days_sales_total}
          />
          <Stats
            title="Last 28 days"
            description="Your total sales in the last 28 days"
            value={balances.last_28_days_sales_total}
          />
          <Stats
            title="Total earnings"
            description="Your all-time net earnings from all products, excluding refunds and chargebacks"
            value={balances.total}
          />
        </div>

        <ActivityFeed items={activity_items} />
      </div>
    </div>
  );
};

export default DashboardPage;
