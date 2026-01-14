import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { isUrlValid } from "$app/utils/url";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";

import { AffiliateForm, AffiliateProduct } from "./Form";

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
      email: props.affiliate.email,
      products: props.affiliate.products,
      fee_percent: props.affiliate.fee_percent,
      apply_to_all_products: props.affiliate.products.every(
        (p) => p.enabled && p.fee_percent === props.affiliate.fee_percent,
      ),
      destination_url: props.affiliate.destination_url,
    },
  });
  const { data, setData, patch, processing, errors } = form;

  const applyToAllProducts = data.affiliate.products.every(
    (p) => p.enabled && p.fee_percent === data.affiliate.fee_percent,
  );

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

    if (
      applyToAllProducts &&
      (!data.affiliate.fee_percent || data.affiliate.fee_percent < 1 || data.affiliate.fee_percent > 90)
    ) {
      form.setError("affiliate.fee_percent", "Commission must be between 1% and 90%");
      showAlert("Commission must be between 1% and 90%", "error");
      return;
    }

    if (!applyToAllProducts && data.affiliate.products.every((p) => !p.enabled)) {
      form.setError("affiliate.products", "Please enable at least one product");
      showAlert("Please enable at least one product", "error");
      return;
    }

    if (
      !applyToAllProducts &&
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

    patch(cast<string>(Routes.affiliate_path(props.affiliate.id)), {
      onError: (errors: Record<string, string | string[]>) => {
        const message = errors.base
          ? Array.isArray(errors.base)
            ? errors.base[0]
            : errors.base
          : "Failed to update affiliate";
        if (message) showAlert(message, "error");
      },
    });
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
        <AffiliateForm
          data={data.affiliate}
          errors={errors}
          processing={processing}
          applyToAllProducts={applyToAllProducts}
          uid={uid}
          headerText="The process of editing is almost identical to adding them. You can change their affiliate fee, the products they are assigned. Their affiliate link will not change."
          emailField={
            <fieldset>
              <legend>
                <label htmlFor={`${uid}email`}>Email</label>
              </legend>
              <input type="email" id={`${uid}email`} value={props.affiliate.email} disabled />
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
          onUpdateDestinationUrl={(value) => setData("affiliate.destination_url", value)}
          onUpdateProduct={(productId, updates) => {
            setData(
              "affiliate.products",
              data.affiliate.products.map((p) => (p.id === productId ? { ...p, ...updates } : p)),
            );
          }}
        />
      </form>
    </div>
  );
}
