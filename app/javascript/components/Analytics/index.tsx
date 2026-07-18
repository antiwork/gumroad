import { differenceInDays, lightFormat, startOfDay } from "date-fns";
import { pickBy } from "lodash-es";
import * as React from "react";

import {
  AnalyticsDataByReferral,
  AnalyticsDataByState,
  fetchAnalyticsDataByReferral,
  fetchAnalyticsDataByState,
} from "$app/data/analytics";
import { assertDefined } from "$app/utils/assert";
import { AbortError } from "$app/utils/request";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { ExportSalesPopover } from "$app/components/Analytics/ExportSalesPopover";
import { LocationsTable } from "$app/components/Analytics/LocationsTable";
import { ProductsPopover } from "$app/components/Analytics/ProductsPopover";
import { ReferrersTable } from "$app/components/Analytics/ReferrersTable";
import { SalesChart } from "$app/components/Analytics/SalesChart";
import { SalesQuickStats } from "$app/components/Analytics/SalesQuickStats";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { showAlert } from "$app/components/server-components/Alert";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Select } from "$app/components/ui/Select";

import placeholder from "$assets/images/placeholders/sales.png";

const MAX_DATE_RANGE_DAYS = 366;
// Must match CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS on the backend.
const MAX_HOURLY_DATE_RANGE_DAYS = 7;

export type Product = {
  name: string;
  id: string;
  alive: boolean;
  unique_permalink: string;
};

export type AnalyticsTotal = {
  sales: number;
  views: number;
  totals: number;
};

export type AnalyticsDailyTotal = {
  date: string;
  month: string;
  monthIndex: number;
  sales: number;
  views: number;
  totals: number;
};

export type AnalyticsReferrerTotals = Record<string, AnalyticsTotal>;

export type AnalyticsData = {
  total: AnalyticsTotal;
  startDate: string;
  endDate: string;
  dailyTotal: AnalyticsDailyTotal[];
  referrerTotal: AnalyticsReferrerTotals;
};

const formatData = (data: AnalyticsDataByReferral, selectedPermalinks: string[]) => {
  const result: AnalyticsData = {
    total: { sales: 0, views: 0, totals: 0 },
    startDate: data.start_date,
    endDate: data.end_date,
    dailyTotal: data.dates_and_months.map(({ date, month, month_index }) => ({
      date,
      month,
      monthIndex: month_index,
      sales: 0,
      views: 0,
      totals: 0,
    })),
    referrerTotal: {},
  };

  const addData = (field: "sales" | "views" | "totals") => {
    const relevantData = pickBy(data.by_referral[field], (_, permalink) => selectedPermalinks.includes(permalink));
    for (const byReferrer of Object.values(relevantData)) {
      for (const [referrer, values] of Object.entries(byReferrer)) {
        for (const [index, value] of values.entries()) {
          result.total[field] += value;
          assertDefined(result.dailyTotal[index])[field] += value;
          result.referrerTotal[referrer] ??= { sales: 0, views: 0, totals: 0 };
          assertDefined(result.referrerTotal[referrer])[field] += value;
        }
      }
    }
  };

  addData("sales");
  addData("views");
  addData("totals");

  return result;
};

export type AnalyticsProps = {
  products: Product[];
  seller_time_zone: string;
  country_codes: Record<string, string>;
  state_names: Record<string, string>;
};

const Analytics = ({ products: initialProducts, seller_time_zone, country_codes, state_names }: AnalyticsProps) => {
  const [products, setProducts] = React.useState(
    initialProducts.map((product) => ({ ...product, selected: product.alive })),
  );
  const [aggregateBy, setAggregateBy] = React.useState<"hourly" | "daily" | "monthly">("daily");
  const dateRange = useAnalyticsDateRange({ maxRangeDays: MAX_DATE_RANGE_DAYS });
  // Hourly buckets are only available for short ranges (the backend rejects wider
  // ones). Compare calendar days, not exact times: the picked dates carry a
  // time-of-day, but only yyyy-MM-dd strings are sent to the backend.
  const rangeDays = differenceInDays(startOfDay(dateRange.to), startOfDay(dateRange.from));
  const canAggregateHourly = rangeDays >= 0 && rangeDays <= MAX_HOURLY_DATE_RANGE_DAYS;
  React.useEffect(() => {
    if (aggregateBy === "hourly" && !canAggregateHourly) setAggregateBy("daily");
  }, [aggregateBy, canAggregateHourly]);
  const hourly = aggregateBy === "hourly" && canAggregateHourly;
  const [data, setData] = React.useState<{
    byReferral: AnalyticsDataByReferral;
    byState: AnalyticsDataByState;
  } | null>(null);
  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const hasContent = products.length > 0;

  const activeRequests = React.useRef<AbortController[] | null>(null);
  React.useEffect(() => {
    const loadData = async () => {
      if (!hasContent) return;

      try {
        if (activeRequests.current) activeRequests.current.forEach((request) => request.abort());
        setData(null);
        const byStateRequest = fetchAnalyticsDataByState({ startTime, endTime });
        const byReferralRequest = fetchAnalyticsDataByReferral({
          startTime,
          endTime,
          interval: hourly ? "hour" : undefined,
        });
        activeRequests.current = [byStateRequest.abort, byReferralRequest.abort];
        const [byState, byReferral] = await Promise.all([byStateRequest.response, byReferralRequest.response]);
        setData({ byState, byReferral });
        activeRequests.current = null;
      } catch (e) {
        if (e instanceof AbortError) return;
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    };
    void loadData();
  }, [startTime, endTime, hourly]);

  const selectedProducts = products.filter((product) => product.selected).map((product) => product.unique_permalink);

  const mainData = React.useMemo(
    () => (data?.byReferral ? formatData(data.byReferral, selectedProducts) : null),
    [data?.byReferral, products],
  );

  return (
    <AnalyticsLayout
      selectedTab="sales"
      actions={
        hasContent ? (
          <>
            <Select
              aria-label="Aggregate by"
              value={aggregateBy}
              onChange={(e) =>
                setAggregateBy(
                  e.target.value === "hourly" ? "hourly" : e.target.value === "monthly" ? "monthly" : "daily",
                )
              }
              wrapperClassName="w-auto"
            >
              {canAggregateHourly ? <option value="hourly">Hourly</option> : null}
              <option value="daily">Daily</option>
              <option value="monthly">Monthly</option>
            </Select>
            <ProductsPopover products={products} setProducts={setProducts} />
            <div className="col-span-2">
              <DateRangePicker {...dateRange} maxRangeDays={MAX_DATE_RANGE_DAYS} />
            </div>
            <ExportSalesPopover />
          </>
        ) : null
      }
    >
      {hasContent ? (
        <div className="space-y-8 p-4 md:p-8">
          <SalesQuickStats total={mainData?.total} />
          {mainData ? (
            <>
              <SalesChart
                data={mainData.dailyTotal}
                startDate={mainData.startDate}
                endDate={mainData.endDate}
                aggregateBy={aggregateBy}
                sellerTimeZone={seller_time_zone}
              />
              <ReferrersTable data={mainData.referrerTotal} />
            </>
          ) : (
            <>
              <InputGroup>
                <LoadingSpinner />
                Loading charts...
              </InputGroup>
              <InputGroup>
                <LoadingSpinner />
                Loading referrers...
              </InputGroup>
            </>
          )}
          {data?.byState ? (
            <LocationsTable
              data={data.byState}
              selectedProducts={selectedProducts}
              countryCodes={country_codes}
              stateNames={state_names}
            />
          ) : (
            <InputGroup>
              <LoadingSpinner />
              Loading locations...
            </InputGroup>
          )}
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <Placeholder>
            <PlaceholderImage src={placeholder} />
            <h2>You're just getting started.</h2>
            <p>
              You don't have any sales yet. Once you do, you'll see them here, along with powerful data that can help
              you see what's working, and what could be working better.
            </p>
            <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
              Learn more about the analytics dashboard
            </a>
          </Placeholder>
        </div>
      )}
    </AnalyticsLayout>
  );
};

export default Analytics;
