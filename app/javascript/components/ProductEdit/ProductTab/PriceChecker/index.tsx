import { InfoCircle } from "@boxicons/react";
import * as React from "react";

import { fetchPriceDistribution, type PriceDistribution } from "$app/data/price_distribution";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useProductEditContext, type Product } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";
import { WithTooltip } from "$app/components/WithTooltip";

import { Checklist } from "./Checklist";
import { DistributionChart } from "./DistributionChart";
import { EmptyState } from "./EmptyState";
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

const checklistFingerprint = (product: Product) =>
  JSON.stringify([product.native_type, product.name, product.description, product.taxonomy_id]);

type Status = "idle" | "loading" | "ok" | "insufficient" | "error";

export const PriceCheckerCard = () => {
  const { uniquePermalink, product, currencyType } = useProductEditContext();

  const [status, setStatus] = React.useState<Status>("idle");
  const [data, setData] = React.useState<PriceDistribution | null>(null);
  const [lastCheckedFingerprint, setLastCheckedFingerprint] = React.useState<string | null>(null);

  const currentFingerprint = checklistFingerprint(product);

  const load = React.useCallback(
    async ({ refresh, signal }: { refresh: boolean; signal: AbortSignal }) => {
      setStatus("loading");
      const fingerprintAtRequest = checklistFingerprint(product);
      try {
        const result = await fetchPriceDistribution(uniquePermalink, { refresh, signal });
        if (signal.aborted) return;
        setData(result);
        setStatus(result.status === "ok" ? "ok" : "insufficient");
        setLastCheckedFingerprint(fingerprintAtRequest);
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
    [uniquePermalink, product],
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

  const isLoading = status === "loading";
  const hasResult = data !== null;
  const hasOk = data?.status === "ok";
  const isInsufficient = data?.status === "insufficient_data";
  const showCtaOverlay = !hasResult && (status === "idle" || isLoading);
  const showRecheck = hasResult;
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

  return (
    <div className="grid gap-3">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <span className="inline-flex font-normal">Price checker</span>
          <WithTooltip position="top" tip={tooltipContent} tooltipProps={{ className: "w-72 max-w-[20rem]" }}>
            <InfoCircle className="size-5" aria-label="Match accuracy details" />
          </WithTooltip>
        </div>
        {showRecheck ? (
          <Button
            size="sm"
            outline
            onClick={() => triggerLoad(true)}
            disabled={recheckDisabled}
            aria-label="Recheck"
            className="min-w-[5rem]"
          >
            {isLoading ? <LoadingSpinner className="size-4" /> : "Recheck"}
          </Button>
        ) : null}
      </div>

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

      {isInsufficient && data?.status === "insufficient_data" ? (
        <EmptyState
          matchCount={data.match_count}
          productTypeLabel={productTypeLabel}
          productNativeType={product.native_type}
          productName={product.name}
          productDescription={product.description}
          taxonomyId={product.taxonomy_id}
        />
      ) : (
        <div className="grid gap-2">
          <div className="relative">
            <DistributionChart
              mode={hasOk ? "real" : "placeholder"}
              histogram={hasOk && data?.status === "ok" ? data.histogram : null}
              summary={hasOk && data?.status === "ok" ? data.summary : null}
              currencyCode={currencyType}
              currentPriceCents={product.price_cents}
            />
            {showCtaOverlay ? (
              <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 px-4">
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
                <p className="max-w-[18rem] text-center text-sm text-muted">
                  How your price compares to similar {productTypeLabel} on Gumroad.
                </p>
              </div>
            ) : null}
          </div>
          {hasOk && data?.status === "ok" ? (
            <TierSubhead
              matchCount={data.match_count}
              tier={data.tier}
              taxonomyLabel={data.taxonomy_label}
              productTypeLabel={productTypeLabel}
            />
          ) : null}
        </div>
      )}
    </div>
  );
};
