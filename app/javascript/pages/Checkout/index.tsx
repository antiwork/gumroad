import { usePage } from "@inertiajs/react";
import React from "react";

import { default as CheckoutPage, CheckoutPageProps } from "$app/components/CheckoutPage";

function Checkout() {
  const {
    discover_url,
    countries,
    us_states,
    ca_provinces,
    clear_cart,
    add_products,
    gift,
    country,
    state,
    address,
    saved_credit_card,
    recaptcha_key,
    paypal_client_id,
    cart,
    max_allowed_cart_products,
    tip_options,
    default_tip_option,
  } = usePage<CheckoutPageProps>().props;

  return (
    <CheckoutPage
      discover_url={discover_url}
      countries={countries}
      us_states={us_states}
      ca_provinces={ca_provinces}
      clear_cart={clear_cart}
      add_products={add_products}
      gift={gift}
      country={country}
      state={state}
      address={address}
      saved_credit_card={saved_credit_card}
      recaptcha_key={recaptcha_key}
      paypal_client_id={paypal_client_id}
      cart={cart}
      max_allowed_cart_products={max_allowed_cart_products}
      tip_options={tip_options}
      default_tip_option={default_tip_option}
    />
  );
}

export default Checkout;
