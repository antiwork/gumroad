import { useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

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

  const { data, setData, patch, processing, errors, setError, clearErrors } = useForm<{
    affiliate: {
      email: string;
      products: AffiliateProduct[];
      fee_percent: number | null;
      apply_to_all_products: boolean;
      destination_url: string | null;
    };
  }>({
    affiliate: {
      email: props.affiliate.email,
      products: props.affiliate.products,
      fee_percent: props.affiliate.fee_percent,
      apply_to_all_products: props.affiliate.products.every(
        (p) => p.enabled && p.fee_percent === props.affiliate.fee_percent,
      ),
      destination_url: props.affiliate.destination_url,
    },
  });

  const applyToAllProducts = data.affiliate.products.every(
    (p) => p.enabled && p.fee_percent === data.affiliate.fee_percent,
  );

  const uid = React.useId();

  const toggleAllProducts = (checked: boolean) => {
    if (checked) {
      setData(
        "affiliate",
        {
          ...data.affiliate,
          products: data.affiliate.products.map((p) => ({ ...p, enabled: true, fee_percent: data.affiliate.fee_percent })),
        },
      );
    } else {
      setData("affiliate", {
        ...data.affiliate,
        products: data.affiliate.products.map((p) => ({ ...p, enabled: false })),
      });
    }
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    clearErrors();

    if (applyToAllProducts && (!data.affiliate.fee_percent || data.affiliate.fee_percent < 1 || data.affiliate.fee_percent > 90)) {
      setError("affiliate.fee_percent", "Commission must be between 1% and 90%");
      showAlert("Commission must be between 1% and 90%", "error");
      return;
    }

    if (!applyToAllProducts && data.affiliate.products.every((p) => !p.enabled)) {
      setError("affiliate.products", "Please enable at least one product");
      showAlert("Please enable at least one product", "error");
      return;
    }

    if (
      !applyToAllProducts &&
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

    patch(Routes.affiliate_path(props.affiliate.id));
  };

  return (
    <div>
      <PageHeader
        className="sticky-top"
        title="Edit Affiliate"
        actions={
          <>
            <NavigationButtonInertia href={Routes.affiliates_path()} disabled={processing}>
              <Icon name="x-square" />
              Cancel
            </NavigationButtonInertia>
            <Button
              color="accent"
              onClick={handleSubmit}
              disabled={processing || !loggedInUser?.policies.direct_affiliate.update}
            >
              {processing ? "Saving..." : "Save changes"}
            </Button>
          </>
        }
      />
      <form onSubmit={handleSubmit}>
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
                        <div className={cx("input", { disabled: processing || !applyToAllProducts })}>
                          <input
                            type="text"
                            autoComplete="off"
                            placeholder="Commission"
                            disabled={processing || !applyToAllProducts}
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
                      disabled={processing || !applyToAllProducts}
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
