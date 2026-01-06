import { Link, useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { SelfServeAffiliateProduct } from "$app/data/affiliates";
import { isUrlValid } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { ToggleSettingRow } from "$app/components/SettingRow";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Placeholder, PlaceholderImage } from "$app/components/ui/Placeholder";
import { Table, TableBody, TableCaption, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";

import placeholderImage from "$assets/images/placeholders/affiliate-signup-form.png";

type InvalidProductAttrs = Set<"commission" | "destination_url">;

type Props = {
  creator_subdomain: string;
  products: SelfServeAffiliateProduct[];
  disable_global_affiliate: boolean;
  global_affiliate_percentage: number;
  affiliates_disabled_reason: string | null;
};

const MIN_FEE_PERCENT = 1;
const MAX_FEE_PERCENT = 90;
const isValidFeePercent = (fee: number | null) => fee !== null && fee >= MIN_FEE_PERCENT && fee <= MAX_FEE_PERCENT;
const validateProduct = (product: SelfServeAffiliateProduct): InvalidProductAttrs => {
  const invalidAttributes: InvalidProductAttrs = new Set();
  const { fee_percent, destination_url, enabled } = product;

  if ((enabled && !fee_percent) || (fee_percent && !isValidFeePercent(fee_percent)))
    invalidAttributes.add("commission");
  if (destination_url && destination_url !== "" && !isUrlValid(destination_url))
    invalidAttributes.add("destination_url");

  return invalidAttributes;
};

const AffiliatesNavigation = () => (
  <Tabs>
    <Tab asChild isSelected={false}>
      <Link href={cast<string>(Routes.affiliates_path())}>Affiliates</Link>
    </Tab>
    <Tab asChild isSelected>
      <Link href={cast<string>(Routes.onboarding_affiliates_path())}>Affiliate Signup Form</Link>
    </Tab>
  </Tabs>
);

export default function AffiliatesOnboarding() {
  const props = cast<Props>(usePage().props);
  const loggedInUser = useLoggedInUser();

  const { data, setData, patch, processing } = useForm({
    products: props.products,
    disable_global_affiliate: props.disable_global_affiliate,
  });

  const enableAffiliateLink = data.products.some(
    ({ enabled, fee_percent }) => enabled && isValidFeePercent(fee_percent),
  );

  const affiliateRequestUrl = Routes.custom_domain_new_affiliate_request_url({ host: props.creator_subdomain });

  const handleSaveChanges = (e: React.FormEvent) => {
    e.preventDefault();

    const hasErrors = data.products.some((product) => validateProduct(product).size > 0);

    if (hasErrors) {
      showAlert("There are some errors on the page. Please fix them and try again.", "error");
      return;
    }

    patch(Routes.affiliate_requests_onboarding_form_path());
  };

  const onToggleDisableGlobalAffiliate = (value: boolean) => {
    setData("disable_global_affiliate", value);
  };

  const onUpdateProductLink = (index: number, updatedValues: Partial<SelfServeAffiliateProduct>) => {
    setData(
      "products",
      data.products.map((product, i) => (i === index ? { ...product, ...updatedValues } : product)),
    );
  };

  return (
    <div>
      <PageHeader
        title="Affiliates"
        actions={
          <>
            <WithTooltip position="bottom" tip={props.affiliates_disabled_reason}>
              <NavigationButtonInertia
                href={cast<string>(Routes.new_affiliate_path())}
                disabled={!loggedInUser?.policies.direct_affiliate.create || props.affiliates_disabled_reason !== null}
              >
                Add affiliate
              </NavigationButtonInertia>
            </WithTooltip>
            <Button
              onClick={handleSaveChanges}
              disabled={processing || !loggedInUser?.policies.affiliate_requests_onboarding_form.update}
              color="accent"
            >
              {processing ? "Saving..." : "Save changes"}
            </Button>
          </>
        }
      >
        <AffiliatesNavigation />
      </PageHeader>
      {data.products.length === 0 ? (
        <section className="p-4! md:p-8!">
          <Placeholder>
            <PlaceholderImage src={placeholderImage} />
            <h2>Almost there!</h2>
            You need a published product to add affiliates.
            <NavigationButtonInertia
              href={Routes.new_product_path()}
              color="accent"
              disabled={!loggedInUser?.policies.product.create}
            >
              New product
            </NavigationButtonInertia>
          </Placeholder>
        </section>
      ) : (
        <form onSubmit={handleSaveChanges}>
          <section className="p-4! md:p-8!">
            <header>
              <h2>Affiliate link</h2>
              <div>
                Anyone can request to become your affiliate by using your affiliate link. Affiliates will earn a
                commission on each sale they refer.
              </div>
              <a href="/help/article/249-affiliate-faq" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            <fieldset>
              <legend>
                <label htmlFor="affiliate-link">Your affiliate link</label>
              </legend>
              <div className="input input-wrapper">
                <input
                  type="text"
                  id="affiliate-link"
                  readOnly
                  disabled={!enableAffiliateLink}
                  defaultValue={affiliateRequestUrl}
                  className="text-singleline"
                />
                {enableAffiliateLink ? (
                  <CopyToClipboard text={affiliateRequestUrl}>
                    <button type="button" className="underline">
                      Copy link
                    </button>
                  </CopyToClipboard>
                ) : null}
              </div>
              {enableAffiliateLink ? null : (
                <div role="alert" className="warning">
                  You must enable and set up the commission for at least one product before sharing your affiliate link.
                </div>
              )}
            </fieldset>
          </section>
          <section className="p-4! md:p-8!">
            <header>
              <h2>Affiliate products</h2>
              <p>Enable specific products you want your affiliates to earn a commission with.</p>
            </header>
            <Table>
              <TableCaption>Enable specific products</TableCaption>
              <TableHeader>
                <TableRow>
                  <TableHead>Enable</TableHead>
                  <TableHead>Product</TableHead>
                  <TableHead>Commission</TableHead>
                  <TableHead>Destination URL (optional)</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.products.map((product, index) => (
                  <ProductRow
                    key={product.id}
                    product={product}
                    disabled={!loggedInUser?.policies.affiliate_requests_onboarding_form.update}
                    onChange={(updatedValues) => onUpdateProductLink(index, updatedValues)}
                  />
                ))}
              </TableBody>
            </Table>
          </section>
          <section className="p-4! md:p-8!">
            <header>
              <h2>Gumroad Affiliate Program</h2>
              <div>
                Being part of Gumroad Affiliate Program enables other creators to share your products in exchange for a{" "}
                {props.global_affiliate_percentage}% commission.
              </div>
              <a href="/help/article/249-affiliate-faq" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            <fieldset>
              <ToggleSettingRow
                label="Opt out of the Gumroad Affiliate Program"
                value={data.disable_global_affiliate}
                onChange={onToggleDisableGlobalAffiliate}
              />
            </fieldset>
          </section>
        </form>
      )}
    </div>
  );
}

type ProductRowProps = {
  product: SelfServeAffiliateProduct;
  disabled: boolean;
  onChange: (value: Partial<SelfServeAffiliateProduct>) => void;
};

const ProductRow = ({ product, disabled, onChange }: ProductRowProps) => {
  const invalidAttrs = validateProduct(product);
  const uid = React.useId();

  return (
    <TableRow>
      <TableCell>
        <input
          id={uid}
          type="checkbox"
          role="switch"
          checked={product.enabled}
          onChange={(evt) => onChange({ enabled: evt.target.checked })}
          aria-label="Enable product"
          disabled={disabled}
        />
      </TableCell>
      <TableCell>
        <label htmlFor={uid}>{product.name}</label>
      </TableCell>
      <TableCell>
        <fieldset className={cx({ danger: invalidAttrs.has("commission") })}>
          <NumberInput onChange={(value) => onChange({ fee_percent: value ?? 0 })} value={product.fee_percent}>
            {(inputProps) => (
              <div className={cx("input", { disabled: disabled || !product.enabled })}>
                <input
                  type="text"
                  autoComplete="off"
                  placeholder="Commission"
                  disabled={disabled || !product.enabled}
                  {...inputProps}
                />
                <div className="pill">%</div>
              </div>
            )}
          </NumberInput>
        </fieldset>
      </TableCell>
      <TableCell>
        <fieldset className={cx({ danger: invalidAttrs.has("destination_url") })}>
          <input
            type="text"
            aria-label="destination_url"
            disabled={disabled || !product.enabled}
            placeholder="https://link.com"
            value={product.destination_url || ""}
            onChange={(event) => onChange({ destination_url: event.target.value.trim() })}
          />
        </fieldset>
      </TableCell>
    </TableRow>
  );
};
