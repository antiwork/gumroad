import { router, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { updateAffiliate } from "$app/data/affiliates";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { isUrlValid } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type AffiliateProduct = {
  id: number;
  name: string;
  enabled: boolean;
  fee_percent: number | null;
  destination_url: string | null;
  referral_url: string;
};

type AffiliateData = {
  id: string;
  email: string;
  destination_url: string | null;
  affiliate_user_name: string;
  fee_percent: number;
  products: AffiliateProduct[];
};

type Props = {
  affiliate: AffiliateData;
  affiliates_disabled_reason: string | null;
};

export default function AffiliatesEdit() {
  const props = usePage<{ props: Props }>().props as unknown as Props;
  const loggedInUser = useLoggedInUser();
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [products, setProducts] = React.useState<AffiliateProduct[]>(props.affiliate.products);
  const [feePercent, setFeePercent] = React.useState<number | null>(props.affiliate.fee_percent);
  const [destinationUrl, setDestinationUrl] = React.useState<string | null>(props.affiliate.destination_url);
  const [errors, setErrors] = React.useState<Map<string, string>>(new Map());

  const applyToAllProducts = products.every((p) => p.enabled && p.fee_percent === feePercent);

  const uid = React.useId();

  const toggleAllProducts = (checked: boolean) => {
    if (checked) {
      setProducts(products.map((p) => ({ ...p, enabled: true, fee_percent: feePercent })));
    } else {
      setProducts(products.map((p) => ({ ...p, enabled: false })));
    }
  };

  const handleSubmit = asyncVoid(async () => {
    const newErrors = new Map<string, string>();

    if (applyToAllProducts && (!feePercent || feePercent < 1 || feePercent > 90)) {
      newErrors.set("feePercent", "Commission must be between 1% and 90%");
    }

    if (!applyToAllProducts && products.every((p) => !p.enabled)) {
      newErrors.set("products", "Please enable at least one product");
    }

    if (!applyToAllProducts && products.some((p) => p.enabled && (!p.fee_percent || p.fee_percent < 1 || p.fee_percent > 90))) {
      newErrors.set("products", "All enabled products must have commission between 1% and 90%");
    }

    if (destinationUrl && destinationUrl !== "" && !isUrlValid(destinationUrl)) {
      newErrors.set("destinationUrl", "Please enter a valid URL");
    }

    if (newErrors.size > 0) {
      setErrors(newErrors);
      const [, firstError] = Array.from(newErrors.entries())[0] || [];
      if (firstError) showAlert(firstError, "error");
      return;
    }

    try {
      setIsSubmitting(true);
      await updateAffiliate({
        id: props.affiliate.id,
        email: props.affiliate.email,
        products: products.map((p) => ({
          id: p.id,
          enabled: p.enabled,
          name: p.name,
          fee_percent: p.fee_percent,
          destination_url: p.destination_url || null,
          referral_url: p.referral_url,
        })),
        fee_percent: feePercent,
        apply_to_all_products: applyToAllProducts,
        destination_url: destinationUrl,
      });
      showAlert("Changes saved!", "success");
      router.visit(Routes.affiliates_path());
    } catch (e) {
      assertResponseError(e);
      showAlert((e as Error).message || "Failed to update affiliate", "error");
    } finally {
      setIsSubmitting(false);
    }
  });

  return (
    <div>
      <PageHeader
        className="sticky-top"
        title="Edit Affiliate"
        actions={
          <>
            <NavigationButtonInertia href={Routes.affiliates_path()} disabled={isSubmitting}>
              <Icon name="x-square" />
              Cancel
            </NavigationButtonInertia>
            <Button
              color="accent"
              onClick={handleSubmit}
              disabled={isSubmitting || !loggedInUser?.policies.direct_affiliate.update}
            >
              {isSubmitting ? "Saving..." : "Save changes"}
            </Button>
          </>
        }
      />
      <form>
        <section className="p-4! md:p-8!">
          <header
            dangerouslySetInnerHTML={{
              __html:
                "The process of editing is almost identical to adding them. You can change their affiliate fee, the products they are assigned. Their affiliate link will not change. <a href='/help/article/333-affiliates-on-gumroad' target='_blank' rel='noreferrer'>Learn more</a>",
            }}
          />
          <fieldset>
            <legend>
              <label htmlFor={`${uid}email`}>Email</label>
            </legend>
            <input
              type="email"
              id={`${uid}email`}
              value={props.affiliate.email}
              disabled
            />
          </fieldset>
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Enable</TableHead>
                <TableHead>Product</TableHead>
                <TableHead>Commission</TableHead>
                <TableHead>
                  <a href="/help/article/333-affiliates-on-gumroad" target="_blank" rel="noreferrer">
                    Destination URL (optional)
                  </a>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              <TableRow>
                <TableCell>
                  <input
                    id={`${uid}enableAllProducts`}
                    type="checkbox"
                    role="switch"
                    checked={applyToAllProducts}
                    onChange={(e) => toggleAllProducts(e.target.checked)}
                    aria-label="Enable all products"
                  />
                </TableCell>
                <TableCell>
                  <label htmlFor={`${uid}enableAllProducts`}>All products</label>
                </TableCell>
                <TableCell>
                  <fieldset className={cx({ danger: errors.has("feePercent") })}>
                    <NumberInput
                      onChange={(value) => {
                        setFeePercent(value);
                        setProducts(products.map((p) => ({ ...p, fee_percent: value })));
                      }}
                      value={feePercent}
                    >
                      {(inputProps) => (
                        <div className={cx("input", { disabled: isSubmitting || !applyToAllProducts })}>
                          <input
                            type="text"
                            autoComplete="off"
                            placeholder="Commission"
                            disabled={isSubmitting || !applyToAllProducts}
                            {...inputProps}
                          />
                          <div className="pill">%</div>
                        </div>
                      )}
                    </NumberInput>
                  </fieldset>
                </TableCell>
                <TableCell>
                  <fieldset className={cx({ danger: errors.has("destinationUrl") })}>
                    <input
                      type="url"
                      value={destinationUrl || ""}
                      placeholder="https://link.com"
                      onChange={(e) => setDestinationUrl(e.target.value)}
                      disabled={isSubmitting || !applyToAllProducts}
                    />
                  </fieldset>
                </TableCell>
              </TableRow>
              {products.map((product) => (
                <TableRow key={product.id}>
                  <TableCell>
                    <input
                      type="checkbox"
                      role="switch"
                      checked={product.enabled}
                      onChange={(e) =>
                        setProducts(products.map((p) => (p.id === product.id ? { ...p, enabled: e.target.checked } : p)))
                      }
                      disabled={isSubmitting}
                    />
                  </TableCell>
                  <TableCell>{product.name}</TableCell>
                  <TableCell>
                    <NumberInput
                      onChange={(value) =>
                        setProducts(products.map((p) => (p.id === product.id ? { ...p, fee_percent: value } : p)))
                      }
                      value={product.fee_percent}
                    >
                      {(inputProps) => (
                        <div className={cx("input", { disabled: isSubmitting || !product.enabled })}>
                          <input
                            type="text"
                            autoComplete="off"
                            placeholder="Commission"
                            disabled={isSubmitting || !product.enabled}
                            {...inputProps}
                          />
                          <div className="pill">%</div>
                        </div>
                      )}
                    </NumberInput>
                  </TableCell>
                  <TableCell>
                    <input
                      type="text"
                      placeholder="https://link.com"
                      value={product.destination_url || ""}
                      onChange={(e) =>
                        setProducts(products.map((p) => (p.id === product.id ? { ...p, destination_url: e.target.value } : p)))
                      }
                      disabled={isSubmitting || !product.enabled}
                    />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </section>
      </form>
    </div>
  );
}
