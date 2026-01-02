import { useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { isValidEmail } from "$app/utils/email";
import { isUrlValid } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";

import { AffiliateForm, AffiliateProduct } from "./Form";

type Props = {
  products: AffiliateProduct[];
  affiliates_disabled_reason: string | null;
};

export default function AffiliatesNew() {
  const props = cast<Props>(usePage().props);
  const loggedInUser = useLoggedInUser();

  const form = useForm<{
    affiliate: {
      email: string;
      products: AffiliateProduct[];
      fee_percent: number | null;
      apply_to_all_products: boolean;
      destination_url: string | null;
    };
  }>({
    affiliate: {
      email: "",
      products: props.products,
      fee_percent: null,
      apply_to_all_products: props.products.length === 0,
      destination_url: null,
    },
  });
  const { data, setData, post, processing, errors } = form;

  const emailInputRef = React.useRef<HTMLInputElement>(null);
  const uid = React.useId();

  const toggleAllProducts = (checked: boolean) => {
    if (checked) {
      setData("affiliate", {
        ...data.affiliate,
        apply_to_all_products: true,
        products: data.affiliate.products.map((p) => ({
          ...p,
          enabled: true,
          fee_percent: data.affiliate.fee_percent,
        })),
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
    form.clearErrors();

    if (!data.affiliate.email || !isValidEmail(data.affiliate.email)) {
      form.setError("affiliate.email", "Valid email is required");
      showAlert("Please enter a valid email address", "error");
      emailInputRef.current?.focus();
      return;
    }

    if (
      data.affiliate.apply_to_all_products &&
      (!data.affiliate.fee_percent || data.affiliate.fee_percent < 1 || data.affiliate.fee_percent > 90)
    ) {
      form.setError("affiliate.fee_percent", "Commission must be between 1% and 90%");
      showAlert("Commission must be between 1% and 90%", "error");
      return;
    }

    if (!data.affiliate.apply_to_all_products && data.affiliate.products.every((p) => !p.enabled)) {
      form.setError("affiliate.products", "Please enable at least one product");
      showAlert("Please enable at least one product", "error");
      return;
    }

    if (
      !data.affiliate.apply_to_all_products &&
      data.affiliate.products.some((p) => p.enabled && (!p.fee_percent || p.fee_percent < 1 || p.fee_percent > 90))
    ) {
      form.setError("affiliate.products", "All enabled products must have commission between 1% and 90%");
      showAlert("All enabled products must have commission between 1% and 90%", "error");
      return;
    }

    if (
      data.affiliate.destination_url &&
      data.affiliate.destination_url !== "" &&
      !isUrlValid(data.affiliate.destination_url)
    ) {
      form.setError("affiliate.destination_url", "Please enter a valid URL");
      showAlert("Please enter a valid URL", "error");
      return;
    }

    post(Routes.affiliates_path(), {
      onError: (errors: Record<string, string | string[]>) => {
        const message = errors.base
          ? Array.isArray(errors.base)
            ? errors.base[0]
            : errors.base
          : "Failed to add affiliate";
        if (message) showAlert(message, "error");
      },
    });
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
        <AffiliateForm
          data={data.affiliate}
          errors={errors}
          processing={processing}
          applyToAllProducts={data.affiliate.apply_to_all_products}
          uid={uid}
          headerText="Add a new affiliate below and we'll send them a unique link to share with their audience. Your affiliate will then earn a commission on each sale they refer."
          emailField={
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
          }
          onToggleAllProducts={toggleAllProducts}
          onUpdateFeePercent={(value) => {
            setData("affiliate", {
              ...data.affiliate,
              fee_percent: value,
              products: data.affiliate.products.map((p) => ({ ...p, fee_percent: value })),
            });
          }}
          onUpdateDestinationUrl={(value) => setData("affiliate", { ...data.affiliate, destination_url: value })}
          onUpdateProduct={(productId, updates) => {
            setData("affiliate", {
              ...data.affiliate,
              products: data.affiliate.products.map((p) => (p.id === productId ? { ...p, ...updates } : p)),
            });
          }}
        />
      </form>
    </div>
  );
}
