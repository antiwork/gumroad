import { useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { SelfServeAffiliateProduct } from "$app/data/affiliates";
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
  const props = usePage<{ props: Props }>().props as unknown as Props;
  const loggedInUser = useLoggedInUser();

  const { data, setData, post, processing, errors, setError, clearErrors } = useForm({
    affiliate: {
      email: "",
      products: props.products,
      fee_percent: null as number | null,
      apply_to_all_products: props.products.length === 0,
      destination_url: null as string | null,
    },
  });

  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const uid = React.useId();

  const toggleAllProducts = (checked: boolean) => {
    if (checked) {
      setData("affiliate", {
        ...data.affiliate,
        apply_to_all_products: true,
        products: data.affiliate.products.map((p) => ({ ...p, enabled: true, fee_percent: data.affiliate.fee_percent })),
      });
    } else {
      setData("affiliate", {
        ...data.affiliate,
        apply_to_all_products: false,
        products: data.affiliate.products.map((p) => ({ ...p, enabled: false })),
      });
    }
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    clearErrors();

    if (!data.affiliate.email) {
      setError("affiliate.email", "Email is required");
      showAlert("Email is required", "error");
      return;
    }
    if (!isValidEmail(data.affiliate.email)) {
      setError("affiliate.email", "Please enter a valid email address");
      showAlert("Please enter a valid email address", "error");
      return;
    }

    if (data.affiliate.apply_to_all_products && (!data.affiliate.fee_percent || data.affiliate.fee_percent < 1 || data.affiliate.fee_percent > 90)) {
      setError("affiliate.fee_percent", "Commission must be between 1% and 90%");
      showAlert("Commission must be between 1% and 90%", "error");
      return;
    }

    if (!data.affiliate.apply_to_all_products && data.affiliate.products.every((p) => !p.enabled)) {
      setError("affiliate.products", "Please enable at least one product");
      showAlert("Please enable at least one product", "error");
      return;
    }

    if (
      !data.affiliate.apply_to_all_products &&
      data.affiliate.products.some((p) => p.enabled && (!p.fee_percent || p.fee_percent < 1 || p.fee_percent > 90))
    ) {
      setError("affiliate.products", "All enabled products must have commission between 1% and 90%");
      showAlert("All enabled products must have commission between 1% and 90%", "error");
      return;
    }

    if (data.affiliate.destination_url && data.affiliate.destination_url !== "" && !isUrlValid(data.affiliate.destination_url)) {
      setError("affiliate.destination_url", "Please enter a valid URL");
      showAlert("Please enter a valid URL", "error");
      return;
    }

    post(Routes.affiliates_path());
  };

  return (
    <div>
      <PageHeader
        className="sticky-top"
        title="New Affiliate"
        actions={
          <>
            <NavigationButtonInertia href={Routes.affiliates_path()} disabled={processing}>
              <Icon name="x-square" />
              Cancel
            </NavigationButtonInertia>
            <Button
              color="accent"
              onClick={handleSubmit}
              disabled={processing || !loggedInUser?.policies.direct_affiliate.create}
            >
              {processing ? "Adding..." : "Add affiliate"}
            </Button>
          </>
        }
      />
      <form onSubmit={handleSubmit}>
        <section className="p-4! md:p-8!">
          <header
            dangerouslySetInnerHTML={{
              __html:
                "Add a new affiliate below and we'll send them a unique link to share with their audience. Your affiliate will then earn a commission on each sale they refer. <a href='/help/article/333-affiliates-on-gumroad' target='_blank' rel='noreferrer'>Learn more</a>",
            }}
          />
          <fieldset className={cx({ danger: errors["affiliate.email"] })}>
            <legend>
              <label htmlFor={`${uid}email`}>Email</label>
            </legend>
            <input
              ref={emailInputRef}
              type="email"
              id={`${uid}email`}
              placeholder="Email of a Gumroad creator"
              value={data.affiliate.email}
              disabled={processing}
              aria-invalid={!!errors["affiliate.email"]}
              onChange={(e) => setData("affiliate", { ...data.affiliate, email: e.target.value })}
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
                    checked={data.affiliate.apply_to_all_products}
                    onChange={(e) => toggleAllProducts(e.target.checked)}
                    aria-label="Enable all products"
                  />
                </TableCell>
                <TableCell>
                  <label htmlFor={`${uid}enableAllProducts`}>All products</label>
                </TableCell>
                <TableCell>
                  <fieldset className={cx({ danger: errors["affiliate.fee_percent"] })}>
                    <NumberInput
                      onChange={(value) => {
                        setData("affiliate", {
                          ...data.affiliate,
                          fee_percent: value,
                          products: data.affiliate.products.map((p) => ({ ...p, fee_percent: value })),
                        });
                      }}
                      value={data.affiliate.fee_percent}
                    >
                      {(inputProps) => (
                        <div className={cx("input", { disabled: processing || !data.affiliate.apply_to_all_products })}>
                          <input
                            type="text"
                            autoComplete="off"
                            placeholder="Commission"
                            disabled={processing || !data.affiliate.apply_to_all_products}
                            {...inputProps}
                          />
                          <div className="pill">%</div>
                        </div>
                      )}
                    </NumberInput>
                  </fieldset>
                </TableCell>
                <TableCell>
                  <fieldset className={cx({ danger: errors["affiliate.destination_url"] })}>
                    <input
                      type="url"
                      value={data.affiliate.destination_url || ""}
                      placeholder="https://link.com"
                      onChange={(e) => setData("affiliate", { ...data.affiliate, destination_url: e.target.value })}
                      disabled={processing || !data.affiliate.apply_to_all_products}
                    />
                  </fieldset>
                </TableCell>
              </TableRow>
              {data.affiliate.products.map((product) => (
                <TableRow key={product.id}>
                  <TableCell>
                    <input
                      type="checkbox"
                      role="switch"
                      checked={product.enabled}
                      onChange={(e) =>
                        setData("affiliate", {
                          ...data.affiliate,
                          products: data.affiliate.products.map((p) =>
                            p.id === product.id ? { ...p, enabled: e.target.checked } : p,
                          ),
                        })
                      }
                      disabled={processing}
                    />
                  </TableCell>
                  <TableCell>{product.name}</TableCell>
                  <TableCell>
                    <NumberInput
                      onChange={(value) =>
                        setData("affiliate", {
                          ...data.affiliate,
                          products: data.affiliate.products.map((p) => (p.id === product.id ? { ...p, fee_percent: value } : p)),
                        })
                      }
                      value={product.fee_percent}
                    >
                      {(inputProps) => (
                        <div className={cx("input", { disabled: processing || !product.enabled })}>
                          <input
                            type="text"
                            autoComplete="off"
                            placeholder="Commission"
                            disabled={processing || !product.enabled}
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
                        setData("affiliate", {
                          ...data.affiliate,
                          products: data.affiliate.products.map((p) =>
                            p.id === product.id ? { ...p, destination_url: e.target.value } : p,
                          ),
                        })
                      }
                      disabled={processing || !product.enabled}
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
