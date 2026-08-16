import { addDays, differenceInDays, lightFormat, parseISO, startOfDay } from "date-fns";
import { pickBy } from "lodash-es";
import * as React from "react";

import {
  AnalyticsDataByReferral,
  AnalyticsDataByState,
  fetchAnalyticsDataByReferral,
  fetchAnalyticsDataByState,
} from "$app/data/analytics";
import { assertDefined } from "$app/utils/assert";
import { AbortError, request, ResponseError } from "$app/utils/request";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { ExportSalesPopover } from "$app/components/Analytics/ExportSalesPopover";
import { LazySalesChart, warmSalesChart } from "$app/components/Analytics/loadChart";
import { AnalyticsTableSkeleton, SalesChartSkeleton } from "$app/components/Analytics/LoadingSkeleton";
import { LocationsTable } from "$app/components/Analytics/LocationsTable";
import { ProductsPopover } from "$app/components/Analytics/ProductsPopover";
import { ReferrersTable } from "$app/components/Analytics/ReferrersTable";
import { SalesChartBoundary } from "$app/components/Analytics/SalesChartBoundary";
import { SalesQuickStats } from "$app/components/Analytics/SalesQuickStats";
import { useAnalyticsDateRange } from "$app/components/Analytics/useAnalyticsDateRange";
import { DateRangePicker } from "$app/components/DateRangePicker";
import { showAlert } from "$app/components/server-components/Alert";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Select } from "$app/components/ui/Select";
import { useUserAgentInfo } from "$app/components/UserAgent";

import placeholder from "$assets/images/placeholders/sales.png";

// Must match CreatorAnalytics::Sales::MAX_HOURLY_DATE_RANGE_DAYS on the backend.
const MAX_HOURLY_DATE_RANGE_DAYS = 7;
// Past this width, daily rendering means thousands of chart points, so we default to monthly.
const WIDE_RANGE_DAYS = 366;
// Names the exported range rather than calling it "the full range": by the time the export is
// confirmed, the picker has usually moved to a narrower one, and only the dates say which is which.
const csvOnItsWay = (range: string) => `A CSV of ${range} is on its way to your email.`;
const withCsvNote = (message: string, exportedRange: string | null) =>
  exportedRange ? `${message} ${csvOnItsWay(exportedRange)}` : message;
const TERMINAL_FAILURE = "Sorry, something went wrong. Please try again.";
type PendingExport = {
  startTime: string;
  endTime: string;
  label: string;
  requested: boolean;
  enqueued: boolean;
  announced: boolean;
  streakEnded: boolean;
  // The last thing the seller was told, when the streak ended without a chart. A late confirmation
  // repeats it rather than replacing the only notice that the range never loaded.
  finalFailure: string | null;
};
// The range to name in a failure alert, once the server has confirmed the export. Every alert in
// the streak carries it, because they replace each other in milliseconds and only the last one
// stays on screen long enough to read.
const csvNoteFor = (pendingExport: PendingExport | null) => {
  if (!pendingExport?.enqueued) return null;
  pendingExport.announced = true;
  return pendingExport.label;
};
// Used where no failure alert will follow, so the promise would otherwise never be made.
const announceCsv = (pendingExport: PendingExport) => {
  if (pendingExport.announced) return;
  pendingExport.announced = true;
  const { finalFailure, label } = pendingExport;
  if (finalFailure) showAlert(withCsvNote(finalFailure, label), "error");
  else showAlert(csvOnItsWay(label), "success");
};

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
  // First date the backend will ever return data for: it clamps every requested range to the
  // seller's account creation date. The picker starts here so "All time" means the same span
  // the chart draws.
  earliest_date: string;
  // Fraction (0..1) of a typical day's revenue this seller has historically booked by
  // the time the page rendered, or null when recent sales history is too thin. Used
  // to weight the projected end-of-day total on the sales chart.
  expected_sales_fraction_of_day: number | null;
  country_codes: Record<string, string>;
  state_names: Record<string, string>;
};

const Analytics = ({
  products: initialProducts,
  seller_time_zone,
  earliest_date,
  expected_sales_fraction_of_day,
  country_codes,
  state_names,
}: AnalyticsProps) => {
  const [products, setProducts] = React.useState(
    initialProducts.map((product) => ({ ...product, selected: product.alive })),
  );
  const [aggregateBy, setAggregateBy] = React.useState<"hourly" | "daily" | "monthly">("daily");
  const minDate = React.useMemo(() => startOfDay(parseISO(earliest_date)), [earliest_date]);
  const dateRange = useAnalyticsDateRange();
  const { locale } = useUserAgentInfo();
  // Hourly buckets are only available for short ranges (the backend rejects wider
  // ones). Compare calendar days, not exact times: the picked dates carry a
  // time-of-day, but only yyyy-MM-dd strings are sent to the backend.
  const rangeDays = differenceInDays(startOfDay(dateRange.to), startOfDay(dateRange.from));
  const canAggregateHourly = rangeDays >= 0 && rangeDays <= MAX_HOURLY_DATE_RANGE_DAYS;
  const isWideRange = rangeDays > WIDE_RANGE_DAYS;
  React.useEffect(() => {
    if (aggregateBy === "hourly" && !canAggregateHourly) setAggregateBy("daily");
  }, [aggregateBy, canAggregateHourly]);
  // Depends only on isWideRange so it fires when the range crosses the threshold, not on
  // every aggregateBy change — the seller can still switch back to Daily explicitly.
  React.useEffect(() => {
    if (isWideRange) setAggregateBy("monthly");
  }, [isWideRange]);
  const hourly = aggregateBy === "hourly" && canAggregateHourly;
  const [data, setData] = React.useState<{
    byReferral: AnalyticsDataByReferral;
    byState: AnalyticsDataByState;
  } | null>(null);
  const startTime = lightFormat(dateRange.from, "yyyy-MM-dd");
  const endTime = lightFormat(dateRange.to, "yyyy-MM-dd");

  const hasContent = products.length > 0;

  const activeRequests = React.useRef<AbortController[] | null>(null);
  // The range the seller actually asked for when the current failure streak began, and whether its
  // CSV is enqueued. Held across retries so the email covers what they asked for rather than
  // whichever halved range a later attempt happens to be on, and so one streak sends one email.
  // At-most-once is best effort: an enqueue whose response is lost is retried and can send twice.
  const pendingExportRef = React.useRef<PendingExport | null>(null);
  // The range the current failure streak is on, including the one the auto-retry is moving to. Any
  // other range is one the seller picked, which starts a fresh streak — otherwise their new range
  // inherits the old one's "CSV is on its way".
  const streakRangeRef = React.useRef<string | null>(null);
  React.useEffect(() => {
    const rangeKey = `${startTime}:${endTime}`;
    if (streakRangeRef.current !== rangeKey) pendingExportRef.current = null;
    streakRangeRef.current = rangeKey;
    // Deliberately not awaited: narrowing the range is what gets the seller a chart back, and it
    // must not queue behind an export endpoint that is slow for the same reason the analytics load
    // just failed. Whichever alert comes first after the server confirms carries the promise — this
    // one when the confirmation lands between retries, otherwise the next failure alert.
    const enqueueExport = (pendingExport: PendingExport) => {
      if (pendingExport.requested || pendingExport.enqueued) return;
      pendingExport.requested = true;
      void request({
        method: "GET",
        accept: "json",
        url: Routes.export_purchases_path({
          start_time: pendingExport.startTime,
          end_time: pendingExport.endTime,
          force_async: true,
          // Bound the CSV by the same seller-clock days the chart buckets by.
          in_seller_time_zone: true,
        }),
      })
        .then((response) => {
          if (!response.ok) throw new ResponseError();
          pendingExport.enqueued = true;
          // Silent while the streak is live: a retry alert is about to replace anything shown here,
          // and those alerts carry the promise themselves.
          if (pendingExport.streakEnded) announceCsv(pendingExport);
        })
        .catch(() => {
          // Let the next failure in this streak enqueue the export again.
          pendingExport.requested = false;
        });
    };
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
        const recovered = pendingExportRef.current;
        pendingExportRef.current = null;
        if (recovered) {
          // The chart is back, so no failure alert will carry the promise from here on.
          recovered.streakEnded = true;
          if (recovered.enqueued) announceCsv(recovered);
        }
      } catch (e) {
        if (e instanceof AbortError) return;
        // rangeDays is the gap between two included endpoints, so 0 is a single day — the
        // narrowest range there is, and the only one with nothing left to halve.
        if (rangeDays <= 0) {
          // Deliberately not cleared: the export for this streak may still be in flight, and its
          // confirmation is worth showing even though the chart never came back. The range check
          // above already retires the streak as soon as the seller picks anything else.
          const exported = pendingExportRef.current;
          if (exported) {
            // This alert is the last one, so nothing after it can carry the promise. A late
            // confirmation repeats it instead of replacing it with a bare success toast.
            exported.streakEnded = true;
            exported.finalFailure = TERMINAL_FAILURE;
            // No narrower range is left to fail either, so it is also the last chance to get the
            // CSV moving.
            enqueueExport(exported);
          }
          showAlert(withCsvNote(TERMINAL_FAILURE, csvNoteFor(exported)), "error");
          return;
        }
        const pendingExport = (pendingExportRef.current ??= {
          startTime,
          endTime,
          label: Intl.DateTimeFormat(locale).formatRange(dateRange.from, dateRange.to),
          requested: false,
          enqueued: false,
          announced: false,
          streakEnded: false,
          finalFailure: null,
        });
        enqueueExport(pendingExport);
        showAlert(
          withCsvNote(
            "This range couldn't load, so we're retrying with the most recent half.",
            csvNoteFor(pendingExport),
          ),
          "error",
        );
        // Move the start forward by whole days so every retry is at least one day narrower and
        // the halving reaches a single day. A midpoint in milliseconds can land mid-day and
        // stall two days short of that.
        const nextFrom = addDays(startOfDay(dateRange.from), Math.ceil(rangeDays / 2));
        streakRangeRef.current = `${lightFormat(nextFrom, "yyyy-MM-dd")}:${endTime}`;
        dateRange.setFrom(nextFrom);
      }
    };
    void loadData();
  }, [startTime, endTime, hourly]);

  const selectedProducts = products.filter((product) => product.selected).map((product) => product.unique_permalink);

  // The chart's code is fetched while the analytics data requests above are still in flight, so it
  // is normally ready by the time there is anything to draw.
  React.useEffect(warmSalesChart, []);

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
              <DateRangePicker {...dateRange} minDate={minDate} />
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
              <SalesChartBoundary>
                <React.Suspense fallback={<SalesChartSkeleton />}>
                  <LazySalesChart
                    data={mainData.dailyTotal}
                    startDate={mainData.startDate}
                    endDate={mainData.endDate}
                    aggregateBy={aggregateBy}
                    sellerTimeZone={seller_time_zone}
                    expectedSalesFraction={expected_sales_fraction_of_day}
                  />
                </React.Suspense>
              </SalesChartBoundary>
              <ReferrersTable data={mainData.referrerTotal} />
            </>
          ) : (
            <>
              <SalesChartSkeleton />
              <AnalyticsTableSkeleton label="referrers" columns={5} />
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
            <AnalyticsTableSkeleton label="locations" columns={4} />
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
