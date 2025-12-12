import { router, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { addAffiliate, SelfServeAffiliateProduct } from "$app/data/affiliates";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { isValidEmail } from "$app/utils/email";
import { isUrlValid } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NumberInput } from "$app/components/NumberInput";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "$app/components/ui/Table";

type AffiliateProduct = SelfServeAffiliateProduct & { referral_url: string };

type Props = {
  products: AffiliateProduct[];
  affiliates_disabled_reason: string | null;
};

export default function AffiliatesNew() {
  const props = cast<Props>(usePage().props);
  const loggedInUser = useLoggedInUser();
  const [isSubmitting, setIsSubmitting] = React.useState(false);
  const [email, setEmail] = React.useState("");
  const [products, setProducts] = React.useState<AffiliateProduct[]>(props.products);
  const [applyToAllProducts, setApplyToAllProducts] = React.useState(props.products.length === 0);
  const [feePercent, setFeePercent] = React.useState<number | null>(null);
  const [destinationUrl, setDestinationUrl] = React.useState<string | null>(null);
  const [errors, setErrors] = React.useState<Map<string, string>>(new Map());

  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const uid = React.useId();

  const toggleAllProducts = (checked: boolean) => {
    if (checked) {
      setApplyToAllProducts(true);
      setProducts(products.map((p) => ({ ...p, enabled: true, fee_percent: feePercent })));
    } else {
      setApplyToAllProducts(false);
      setProducts(products.map((p) => ({ ...p, enabled: false })));
    }
  };

  const handleSubmit = asyncVoid(async () => {
    const newErrors = new Map<string, string>();

    if (!email) newErrors.set("email", "Email is required");
    else if (!isValidEmail(email)) newErrors.set("email", "Please enter a valid email address");

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
      await addAffiliate({
        email,
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
      showAlert("Affiliate added successfully!", "success");
      router.visit(Routes.affiliates_path());
    } catch (e) {
      assertResponseError(e);
      showAlert((e as Error).message || "Failed to add affiliate", "error");
    } finally {
      setIsSubmitting(false);
    }
  });

  return (
    <div>
      <PageHeader
        className="sticky-top"
        title="New Affiliate"
        actions={
          <>
            <NavigationButtonInertia href={Routes.affiliates_path()} disabled={isSubmitting}>
              <Icon name="x-square" />
              Cancel
            </NavigationButtonInertia>
            <Button
              color="accent"
              onClick={handleSubmit}
              disabled={isSubmitting || !loggedInUser?.policies.direct_affiliate.create}
            >
              {isSubmitting ? "Adding..." : "Add affiliate"}
            </Button>
          </>
        }
      />
      <form>
        <section className="p-4! md:p-8!">
          <header
            dangerouslySetInnerHTML={{
              __html:
                "Add a new affiliate below and we'll send them a unique link to share with their audience. Your affiliate will then earn a commission on each sale they refer. <a href='/help/article/333-affiliates-on-gumroad' target='_blank' rel='noreferrer'>Learn more</a>",
            }}
          />
          <fieldset className={cx({ danger: errors.has("email") })}>
            <legend>
              <label htmlFor={`${uid}email`}>Email</label>
            </legend>
            <input
              ref={emailInputRef}
              type="email"
              id={`${uid}email`}
              placeholder="Email of a Gumroad creator"
              value={email}
              disabled={isSubmitting}
              aria-invalid={errors.has("email")}
              onChange={(e) => {
                setEmail(e.target.value);
                if (errors.has("email")) {
                  const newErrors = new Map(errors);
                  newErrors.delete("email");
                  setErrors(newErrors);
                }
              }}
              autoFocus
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
