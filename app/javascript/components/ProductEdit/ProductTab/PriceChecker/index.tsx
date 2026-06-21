import { InfoCircle, RefreshCcw } from "@boxicons/react";
import * as React from "react";

import { fetchPriceDistribution, type PriceDistribution } from "$app/data/price_distribution";
import { classNames } from "$app/utils/classNames";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useProductEditContext, type Product } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";
import { WithTooltip } from "$app/components/WithTooltip";

import { Checklist } from "./Checklist";
import { DistributionChart, type PriceMarker } from "./DistributionChart";
import { TierSubhead } from "./TierSubhead";

const NATIVE_TYPE_LABELS: Record<string, string> = {
  digital: "digital products",
  course: "courses",
  ebook: "ebooks",
  membership: "memberships",
  physical: "physical products",
  bundle: "bundles",
  podcast: "podcasts",
  audiobook: "audiobooks",
  newsletter: "newsletters",
  call: "1-on-1 calls",
  commission: "commissions",
  coffee: "tip jars",
};

const labelFor = (nativeType: string | null | undefined) =>
  (nativeType && NATIVE_TYPE_LABELS[nativeType]) || "products";

const checklistFingerprint = (product: Product, currencyCode: string) =>
  JSON.stringify([product.native_type, product.name, product.description, product.taxonomy_id, currencyCode]);

type Status = "idle" | "loading" | "ok" | "insufficient" | "error";

const VARIANT_LABEL_MAX = 12;

const truncateLabel = (raw: string) =>
  raw.length > VARIANT_LABEL_MAX ? `${raw.slice(0, VARIANT_LABEL_MAX).trimEnd()}…` : raw;

const buildPriceMarkers = (product: Product): PriceMarker[] => {
  if (product.native_type === "membership") {
    return [{ id: "base", label: "Your price", valueCents: product.price_cents }];
  }
  const paidVariants = product.variants.filter(
    (variant) => "price_difference_cents" in variant && (variant.price_difference_cents ?? 0) > 0,
  );
  if (paidVariants.length === 0) {
    return [{ id: "base", label: "Your price", valueCents: product.price_cents }];
  }
  return [
    { id: "base", label: "Base price", valueCents: product.price_cents },
    ...paidVariants.map((variant) => ({
      id: variant.id ?? variant.name ?? `variant-${variant.price_difference_cents ?? 0}`,
      label: truncateLabel(variant.name.trim() || "Variant"),
      valueCents: product.price_cents + (variant.price_difference_cents ?? 0),
    })),
  ];
};

export const PriceCheckerCard = () => {
  const { uniquePermalink, product, currencyType } = useProductEditContext();

  const [status, setStatus] = React.useState<Status>("idle");
  const [data, setData] = React.useState<PriceDistribution | null>(null);
  const [lastCheckedFingerprint, setLastCheckedFingerprint] = React.useState<string | null>(null);

  const currentFingerprint = checklistFingerprint(product, currencyType);

  const load = React.useCallback(
    async ({ refresh, signal }: { refresh: boolean; signal: AbortSignal }) => {
      setStatus("loading");
      const fingerprintAtRequest = checklistFingerprint(product, currencyType);
      try {
        const overrides = {
          name: product.name,
          description: product.description,
          taxonomy_id: product.taxonomy_id,
          native_type: product.native_type,
          currency_code: currencyType,
        };
        const result = await fetchPriceDistribution(uniquePermalink, { refresh, overrides, signal });
        if (signal.aborted) return;
        setData(result);
        setStatus(result.status === "ok" ? "ok" : "insufficient");
        setLastCheckedFingerprint(fingerprintAtRequest);
        if (typeof gtag !== "undefined") {
          gtag("event", "price_check_run", {
            tier: result.tier,
            match_count: result.match_count,
            native_type: product.native_type,
            currency_code: result.currency_code,
            send_to: "gumroad",
          });
        }
      } catch (e) {
        if (signal.aborted) return;
        try {
          assertResponseError(e);
        } catch {
          setStatus("error");
          throw e;
        }
        setStatus("error");
      }
    },
    [uniquePermalink, product, currencyType],
  );

  const triggerLoad = React.useCallback(
    (refresh: boolean) => {
      const controller = new AbortController();
      void load({ refresh, signal: controller.signal });
      return () => controller.abort();
    },
    [load],
  );

  const productTypeLabel = labelFor(product.native_type);
  const priceMarkers = React.useMemo(() => buildPriceMarkers(product), [product]);

  const isLoading = status === "loading";
  const hasResult = data !== null;
  const hasOk = data?.status === "ok";
  const isInsufficient = data?.status === "insufficient_data";
  const recheckDisabled = isLoading || lastCheckedFingerprint === currentFingerprint;

  const tooltipContent = (
    <Checklist
      productNativeType={product.native_type}
      productName={product.name}
      productDescription={product.description}
      taxonomyId={product.taxonomy_id}
      productTypeLabel={productTypeLabel}
      tagline={`How your price compares to similar ${productTypeLabel} on Gumroad.`}
    />
  );

  if (!hasResult) {
    return (
      <div className="grid min-h-64 content-center justify-items-center gap-3 rounded-sm border border-dashed border-border bg-background p-4 text-center xl:min-h-80">
        <h2>Price checker</h2>
        <p>How your price compares to similar {productTypeLabel} on Gumroad.</p>
        <Button color="primary" onClick={() => triggerLoad(false)} disabled={isLoading}>
          {isLoading ? (
            <>
              <LoadingSpinner className="size-4" />
              Checking…
            </>
          ) : (
            "Check prices"
          )}
        </Button>
      </div>
    );
  }

  const refreshButton = (
    <WithTooltip tip="Refresh" className={classNames("shrink-0", { invisible: recheckDisabled })}>
      <Button size="icon" onClick={() => triggerLoad(true)} aria-label="Refresh">
        <RefreshCcw className="size-5" />
      </Button>
    </WithTooltip>
  );

  const chartHeaderRow = (
    <div className="flex items-start justify-between gap-2">
      <div className="flex items-center gap-2">
        <span className="inline-flex font-normal">Price checker</span>
        <WithTooltip
          position="bottom"
          tip={tooltipContent}
          tooltipProps={{ className: "w-64 max-w-[calc(100vw-2rem)]" }}
        >
          <button
            type="button"
            aria-label="Match accuracy details"
            className="inline-flex appearance-none items-center justify-center border-0 bg-transparent p-0 text-current [-webkit-tap-highlight-color:transparent] focus:outline-none"
          >
            <InfoCircle className="size-5" />
          </button>
        </WithTooltip>
      </div>
      {refreshButton}
    </div>
  );

  return (
    <div className="grid gap-3">
      {status === "error" ? (
        <Alert variant="danger">
          <div className="flex items-center justify-between gap-2">
            <span>Couldn&apos;t load price comparison.</span>
            <Button size="sm" outline onClick={() => triggerLoad(true)}>
              Retry
            </Button>
          </div>
        </Alert>
      ) : null}

      {isInsufficient && data.status === "insufficient_data" ? (
        <div className="grid min-h-64 content-between gap-3 rounded-sm border border-dashed border-border bg-background p-4 xl:min-h-80">
          <div className="flex items-start justify-between gap-2">
            <div className="grid min-w-0 flex-1 gap-1 text-sm">
              <div className="font-medium text-foreground">Not enough comparable products yet</div>
              <div className="text-muted">
                We found {data.match_count} similar {productTypeLabel} on Gumroad.
              </div>
            </div>
            <WithTooltip tip="Refresh" className="shrink-0">
              <Button size="icon" onClick={() => triggerLoad(true)} disabled={recheckDisabled} aria-label="Refresh">
                <RefreshCcw className="size-5" />
              </Button>
            </WithTooltip>
          </div>
          <Checklist
            productNativeType={product.native_type}
            productName={product.name}
            productDescription={product.description}
            taxonomyId={product.taxonomy_id}
            productTypeLabel={productTypeLabel}
          />
        </div>
      ) : hasOk && data.status === "ok" ? (
        <div className="grid min-h-64 grid-rows-[auto_1fr_auto] gap-3 rounded-sm border border-border bg-background p-4 xl:min-h-80">
          {chartHeaderRow}
          <DistributionChart
            histogram={data.histogram}
            summary={data.summary}
            currencyCode={currencyType}
            priceMarkers={priceMarkers}
          />
          <TierSubhead
            matchCount={data.match_count}
            tier={data.tier}
            taxonomyLabel={data.taxonomy_label}
            productTypeLabel={productTypeLabel}
          />
        </div>
      ) : null}
    </div>
  );
};
