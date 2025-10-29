import { router } from "@inertiajs/react";
import { lightFormat } from "date-fns";
import * as React from "react";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { ProductsPopover } from "$app/components/Analytics/ProductsPopover";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { ChurnChart } from "$app/components/Churn/ChurnChart";
import ChurnQuickStats from "$app/components/Churn/ChurnQuickStats";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { LoadingSpinner } from "$app/components/LoadingSpinner";

import placeholder from "$assets/images/placeholders/sales.png";

export type ChurnData = {
  start_date: string;
  end_date: string;
  metrics: {
    customer_churn_rate: number;
    last_period_churn_rate: number;
    churned_subscribers: number;
    churned_mrr_cents: number;
  };
  daily_data: {
    date: string;
    month: string;
    month_index: number;
    customer_churn_rate: number;
    churned_subscribers: number;
    churned_mrr_cents: number;
    active_at_start: number;
    new_subscribers: number;
  }[];
};

export type Product = {
  id: string;
  name: string;
  unique_permalink: string;
  alive: boolean;
};

export type ChurnProps = {
  churn_props: {
    has_subscription_products: boolean;
    products: Product[];
  };
  churn_data: ChurnData | null;
};

const Churn = ({ churn_props, churn_data }: ChurnProps) => {
  const { has_subscription_products, products: initialProducts } = churn_props;
  const dateRange = useAnalyticsDateRange();
  const [products, setProducts] = React.useState(
    initialProducts.map((product) => ({ ...product, selected: product.alive })),
  );
  const [aggregateBy, setAggregateBy] = React.useState<"daily" | "monthly">("daily");

  const hasContent = has_subscription_products;

  // Handle date range changes using Inertia partial reload
  React.useEffect(() => {
    if (!hasContent) return;

    const fromDate = lightFormat(dateRange.from, "yyyy-MM-dd");
    const toDate = lightFormat(dateRange.to, "yyyy-MM-dd");

    const selectedProductIds = products.reduce<string[]>((ids, { id, selected }) => {
      if (selected) ids.push(id);
      return ids;
    }, []);

    router.reload({
      only: ["churn_data"],
      data: {
        from: fromDate,
        to: toDate,
        products: selectedProductIds,
      },
    });
  }, [dateRange.from, dateRange.to, hasContent, products]);

  return (
    <AnalyticsLayout
      selectedTab="churn"
      actions={
        hasContent ? (
          <>
            <select
              aria-label="Aggregate by"
              onChange={(e) => setAggregateBy(e.target.value === "daily" ? "daily" : "monthly")}
              className="w-auto"
            >
              <option value="daily">Daily</option>
              <option value="monthly">Monthly</option>
            </select>
            <ProductsPopover products={products} setProducts={setProducts} />
            <DateRangePicker {...dateRange} />
          </>
        ) : null
      }
    >
      {hasContent ? (
        <div className="space-y-8 p-4 md:p-8">
          <ChurnQuickStats metrics={churn_data?.metrics} />
          {churn_data ? (
            <ChurnChart data={churn_data.daily_data} aggregateBy={aggregateBy} />
          ) : (
            <div className="input">
              <LoadingSpinner />
              Loading charts...
            </div>
          )}
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>No subscription products yet</h2>
            <p>
              Churn analytics are available for creators with active subscription products. Create a membership or
              subscription product to start tracking subscriber retention.
            </p>
            <a href={Routes.help_center_article_path("172-memberships")} target="_blank" rel="noreferrer">
              Learn more about memberships
            </a>
          </div>
        </div>
      )}
    </AnalyticsLayout>
  );
};

export default Churn;
