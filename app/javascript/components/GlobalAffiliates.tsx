import cx from "classnames";
import * as React from "react";

import { searchGlobalAffiliatesProductEligibility, Product } from "$app/data/global_affiliates";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useDomains, useDiscoverUrl } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";

const DiscoverLinkSection = ({
  globalAffiliateId,
  totalSales,
  cookieExpiryDays,
  affiliateQueryParam,
}: {
  globalAffiliateId: number;
  totalSales: string;
  cookieExpiryDays: number;
  affiliateQueryParam: string;
}) => {
  const baseDiscoverUrl = useDiscoverUrl();
  const discoverUrl = `${baseDiscoverUrl}?${affiliateQueryParam}=${globalAffiliateId}`;
  return (
    <section className="!p-4 md:!p-8">
      <header>
        <h2>Affiliate link</h2>
        <p>Earn 10% for each referral sale made by your link.</p>
        <a href="/help/article/333-affiliates-on-gumroad" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </header>
      <fieldset>
        <legend>Your Discover affiliate link</legend>
        <div className="input">
          <div className="input">{discoverUrl}</div>
          <CopyToClipboard text={discoverUrl} tooltipPosition="bottom">
            <Button className="pill">Copy link</Button>
          </CopyToClipboard>
        </div>
        <small>
          You will be attributed any sales you referred within {cookieExpiryDays} days, even if they're for different
          products you linked to.
        </small>
        <small>
          To date, you have made <strong>{totalSales}</strong> from Gumroad referrals.
        </small>
      </fieldset>
    </section>
  );
};

const LinkGenerationSection = ({
  globalAffiliateId,
  affiliateQueryParam,
}: {
  globalAffiliateId: number;
  affiliateQueryParam: string;
}) => {
  const { rootDomain, shortDomain } = useDomains();
  const [inputLink, setInputLink] = React.useState("");
  const [generatedLink, setGeneratedLink] = React.useState("");
  const [hasError, setHasError] = React.useState(false);

  return (
    <section className="!p-4 md:!p-8">
      <header>
        <h2>Affiliate link generator</h2>
        <p>
          You can add{" "}
          <strong>
            ?{affiliateQueryParam}={globalAffiliateId}
          </strong>{" "}
          to the end of any link or use the generator to automatically add it for you.
        </p>
      </header>
      <fieldset className={cx({ danger: hasError })}>
        <legend>Destination page URL</legend>
        <div className="input">
          <input
            placeholder="Paste a destination page URL"
            value={inputLink}
            onChange={(evt) => setInputLink(evt.target.value)}
          />
          <Button
            className="pill"
            onClick={() => {
              try {
                const url = new URL(inputLink);
                const isGumroadDomain = [rootDomain, shortDomain].some((domain) => url.host.endsWith(domain));
                if (isGumroadDomain) {
                  url.searchParams.set(affiliateQueryParam, globalAffiliateId.toString());
                  setGeneratedLink(url.toString());
                  setHasError(false);
                } else {
                  setHasError(true);
                }
              } catch {
                setHasError(true);
              }
            }}
          >
            Generate link
          </Button>
        </div>
        {hasError ? (
          <div role="alert" className={cx({ danger: hasError })}>
            Invalid URL. Make sure your URL is a Gumroad URL and starts with "http" or "https".
          </div>
        ) : null}
      </fieldset>
      <fieldset>
        <legend>Your affiliate link</legend>
        <div className="input">
          <div className="input">{generatedLink}</div>
          <CopyToClipboard text={generatedLink} tooltipPosition="bottom">
            <Button className="pill">Copy link</Button>
          </CopyToClipboard>
        </div>
        <small>Copy this affiliate link and share it with your audience</small>
      </fieldset>
    </section>
  );
};

type ProductEligibilityResult = {
  isLoading: boolean;
  product: Product | null;
  error: { type: "danger" | "warning"; message: string | null } | null;
};

const ProductEligibilitySection = ({
  globalAffiliateId,
  affiliateQueryParam,
}: {
  globalAffiliateId: number;
  affiliateQueryParam: string;
}) => {
  const [query, setQuery] = React.useState("");
  const [result, setResult] = React.useState<ProductEligibilityResult>({
    isLoading: false,
    product: null,
    error: null,
  });

  return (
    <section className="!p-4 md:!p-8">
      <header>
        <h2>How to know if a product is eligible</h2>
        <p>
          All products published on Discover are part of this program. You can check if any specific product is on
          Discover by entering the product URL here.
        </p>
      </header>
      <fieldset>
        <legend>Product URL</legend>
        <div className="input">
          <input
            placeholder="Paste a product URL"
            value={query}
            onChange={(e) => {
              setQuery(e.target.value);
              setResult({
                isLoading: false,
                product: null,
                error: null,
              });
            }}
            onKeyDown={asyncVoid(async (e) => {
              if (result.isLoading || e.key !== "Enter") return;
              setResult({
                isLoading: true,
                product: null,
                error: null,
              });
              if (query.length === 0) {
                setResult({
                  isLoading: false,
                  product: null,
                  error: {
                    type: "danger",
                    message: "URL must be provided",
                  },
                });
                return;
              }

              try {
                const product = await searchGlobalAffiliatesProductEligibility({ query });
                if (product.recommendable) {
                  const url = new URL(product.short_url);
                  url.searchParams.set(affiliateQueryParam, globalAffiliateId.toString());
                  setResult({
                    isLoading: false,
                    product: { ...product, short_url: url.toString() },
                    error: null,
                  });
                } else {
                  setResult({
                    isLoading: false,
                    product: null,
                    error: {
                      type: "warning",
                      message: "This product is not eligible for the Gumroad Affiliate Program.",
                    },
                  });
                }
              } catch (e) {
                assertResponseError(e);
                setResult({
                  isLoading: false,
                  product: null,
                  error: { type: "danger", message: e.message },
                });
              }
            })}
          />
          <Icon name="solid-search" />
        </div>
      </fieldset>
      {result.isLoading ? <LoadingSpinner /> : null}
      {result.product ? (
        <div className="stack">
          <div>
            <a href={result.product.short_url} target="_blank" rel="noreferrer">
              {result.product.name}
            </a>
            <span>{result.product.formatted_price}</span>
            <CopyToClipboard text={result.product.short_url} tooltipPosition="bottom">
              <Button>
                <Icon name="link" />
                Copy link
              </Button>
            </CopyToClipboard>
          </div>
        </div>
      ) : null}
      {result.error ? (
        <div role="alert" className={result.error.type}>
          {result.error.message}
        </div>
      ) : null}
    </section>
  );
};

type Props = {
  globalAffiliateId: number;
  totalSales: string;
  cookieExpiryDays: number;
  affiliateQueryParam: string;
};
export const GlobalAffiliates = ({ globalAffiliateId, totalSales, cookieExpiryDays, affiliateQueryParam }: Props) => (
  <form>
    <DiscoverLinkSection
      globalAffiliateId={globalAffiliateId}
      totalSales={totalSales}
      cookieExpiryDays={cookieExpiryDays}
      affiliateQueryParam={affiliateQueryParam}
    />
    <LinkGenerationSection globalAffiliateId={globalAffiliateId} affiliateQueryParam={affiliateQueryParam} />
    <ProductEligibilitySection globalAffiliateId={globalAffiliateId} affiliateQueryParam={affiliateQueryParam} />
  </form>
);
