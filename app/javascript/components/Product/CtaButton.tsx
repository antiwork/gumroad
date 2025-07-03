import * as React from "react";

import { trackUserProductAction } from "$app/data/user_action_event";
import { CustomButtonTextOption } from "$app/parsers/product";
import { formatInstallmentPaymentSchedule } from "$app/utils/price";
import { assertResponseError } from "$app/utils/request";
import { trackProductEvent } from "$app/utils/user_analytics";

import { Button, NavigationButton } from "$app/components/Button";
import { ButtonColor } from "$app/components/design";
import { Modal } from "$app/components/Modal";
import { getNotForSaleMessage, Product, ProductDiscount, Purchase } from "$app/components/Product";
import {
  applySelection,
  hasMetDiscountConditions,
  PriceSelection,
} from "$app/components/Product/ConfigurationSelector";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = {
  product: Product;
  purchase: Purchase | null;
  discountCode: ProductDiscount | null;
  selection: PriceSelection;
  label: string | undefined;
  showInstallmentPlanNotes?: boolean;
  onClick?: React.MouseEventHandler<HTMLAnchorElement> | undefined;
  outline?: boolean | undefined;
  color?: ButtonColor | undefined;
};

export const trackCtaClick = ({
  sellerId,
  permalink,
  name,
}: {
  sellerId: string | undefined;
  permalink: string;
  name: string;
}) => {
  if (sellerId)
    trackProductEvent(sellerId, {
      permalink,
      action: "iwantthis",
      product_name: name,
    });
  trackUserProductAction({
    name: "i_want_this",
    permalink,
  }).catch(assertResponseError);
};

// TODO replace this with a free-form input
const ctaNames = {
  i_want_this_prompt: "I want this!",
  buy_this_prompt: "Buy this",
  pay_prompt: "Pay",
  donate_prompt: "Donate",
  support_prompt: "Support",
  tip_prompt: "Tip",
};
export const getCtaName = (cta: CustomButtonTextOption) => ctaNames[cta];

const PARAMETERS_NOT_INHERITED_FROM_URL = new Set([
  "code",
  "option",
  "pay_in_installments",
  "price",
  "product",
  "quantity",
  "recurrence",
  "referrer",
  "rent",
  "target_resource_id",
  "target_resource_type",
  "utm_campaign",
  "utm_content",
  "utm_medium",
  "utm_source",
  "utm_term",
]);

export const defaultCtaButtonText = ({
  purchase,
  product,
  selection,
}: {
  product: Product;
  purchase: Purchase | null;
  selection: PriceSelection;
}) =>
  purchase
    ? "Purchase again"
    : product.recurrences
      ? "Subscribe"
      : selection.rent
        ? "Rent"
        : product.custom_button_text_option
          ? getCtaName(product.custom_button_text_option)
          : "I want this!";

const CtaButtonInner = React.forwardRef<HTMLAnchorElement, Props>(
  (
    {
      product,
      purchase,
      discountCode,
      selection,
      label,
      onClick,
      outline,
      color = "accent",
      showInstallmentPlanNotes = false,
    },
    ref,
  ) => {
    const { searchParams } = new URL(useOriginalLocation());

    const [referrer, setReferrer] = React.useState("");
    useRunOnce(() => setReferrer(document.referrer));

    const { selectedOption, pppDiscounted, discountedPriceCents } = applySelection(
      product,
      discountCode?.valid ? discountCode.discount : null,
      selection,
    );

    const url = new URL(Routes.checkout_index_url());

    const transformations: Record<string, string> = { a: "affiliate_id" };

    for (const [key, value] of searchParams.entries()) {
      if (PARAMETERS_NOT_INHERITED_FROM_URL.has(key)) continue;
      url.searchParams.set(transformations[key] ?? key, value);
    }

    url.searchParams.set("product", product.permalink);
    if (selection.optionId) url.searchParams.set("option", selection.optionId);
    if (selection.recurrence) url.searchParams.set("recurrence", selection.recurrence);
    if (selection.callStartTime) url.searchParams.set("call_start_time", selection.callStartTime);
    url.searchParams.set("quantity", selection.quantity.toString());
    if (selection.rent) url.searchParams.set("rent", "true");
    let price = selection.price.value ?? product.price_cents + (selectedOption?.price_difference_cents ?? 0);
    if ((product.pwyw || selectedOption?.is_pwyw) && selection.price.value != null) {
      if (pppDiscounted && product.ppp_details) {
        price /= product.ppp_details.factor;
      } else if (discountCode?.valid && hasMetDiscountConditions(discountCode.discount, selection.quantity)) {
        if (discountCode.discount.type === "percent") price /= (100 - discountCode.discount.percents) / 100.0;
        else price += discountCode.discount.cents;
      }

      url.searchParams.set("price", Math.round(price).toString());
    }
    if (discountCode?.valid && hasMetDiscountConditions(discountCode.discount, selection.quantity) && !pppDiscounted)
      url.searchParams.set("code", discountCode.code);

    const referrerValue = searchParams.get("referrer") || referrer || null;
    if (referrerValue) url.searchParams.set("referrer", referrerValue);

    if (getNotForSaleMessage(product)) return null;

    const urlWithInstallments = new URL(url);
    urlWithInstallments.searchParams.set("pay_in_installments", "true");

    const buttonCommonProps = {
      target: "_top",
      onClick: (evt: React.MouseEvent<HTMLAnchorElement>) => {
        onClick?.(evt);
        if (evt.defaultPrevented) return;
        trackCtaClick({
          sellerId: product.seller?.id,
          name: product.name,
          permalink: product.permalink,
        });
      },
      // Resolves a Safari rendering bug that makes the button too tall
      style: { alignItems: "unset" },
    };

    return (
      <>
        <NavigationButton ref={ref} href={url.toString()} color={color} outline={outline} {...buttonCommonProps}>
          {label ??
            defaultCtaButtonText({
              purchase,
              product,
              selection,
            })}
        </NavigationButton>

        {product.installment_plan && product.installment_plan.number_of_installments > 1 ? (
          <>
            <NavigationButton color="black" href={urlWithInstallments.toString()} {...buttonCommonProps}>
              Pay in {product.installment_plan.number_of_installments} installments
            </NavigationButton>
            {showInstallmentPlanNotes ? (
              <small className="text-center">
                {formatInstallmentPaymentSchedule(
                  discountedPriceCents,
                  product.currency_code,
                  product.installment_plan.number_of_installments,
                )}
              </small>
            ) : null}
          </>
        ) : null}
      </>
    );
  },
);
CtaButtonInner.displayName = "InnerCtaButton";

export const CtaButton = React.forwardRef<HTMLAnchorElement, Props>((props, ref) => {
  if (props.purchase?.subscription_has_lapsed)
    return (
      <ResumeSubscriptionModal
        product={props.product}
        purchase={props.purchase}
        discountCode={props.discountCode}
        selection={props.selection}
        onStartNewSubscription={props.onClick}
        ctaButtonRef={ref}
        ctaLabel={props.label}
      />
    );

  return <CtaButtonInner {...props} ref={ref} />;
});
CtaButton.displayName = "CtaButton";

const ResumeSubscriptionModal = ({
  product,
  purchase,
  discountCode,
  selection,
  onStartNewSubscription,
  ctaButtonRef,
  ctaLabel,
}: {
  product: Product;
  purchase: Purchase;
  selection: PriceSelection;
  onStartNewSubscription: React.MouseEventHandler<HTMLAnchorElement> | undefined;
  ctaLabel: string | undefined;
  discountCode?: ProductDiscount | null;
  ctaButtonRef?: React.ForwardedRef<HTMLAnchorElement>;
}) => {
  const [showResumeSubscriptionModal, setShowResumeSubscriptionModal] = React.useState(false);

  if (purchase.membership === null) return null;

  return (
    <>
      <a ref={ctaButtonRef} className="contents">
        <Button color="accent" onClick={() => setShowResumeSubscriptionModal(true)}>
          {ctaLabel ??
            defaultCtaButtonText({
              purchase,
              product,
              selection,
            })}
        </Button>
      </a>
      {showResumeSubscriptionModal ? (
        <Modal
          open={showResumeSubscriptionModal}
          onClose={() => setShowResumeSubscriptionModal(false)}
          title="Resume your previous subscription?"
          footer={
            <>
              <CtaButtonInner
                product={product}
                purchase={purchase}
                discountCode={discountCode ?? null}
                selection={selection}
                label="No, start a new subscription"
                showInstallmentPlanNotes
                outline
                color="filled"
                onClick={onStartNewSubscription}
              />
              <NavigationButton
                color="primary"
                onClick={() => setShowResumeSubscriptionModal(false)}
                href={purchase.membership.manage_url}
              >
                Yes, resume subscription
              </NavigationButton>
            </>
          }
        >
          <p>
            You've previously subscribed to this product. Would you like to <b>pick up where you left off, </b>
            or <b>start fresh with a new subscription</b>?
          </p>
        </Modal>
      ) : null}
    </>
  );
};
