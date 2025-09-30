import { usePage } from "@inertiajs/react";
import React from "react";

import { default as NewProductPage, NewProductPageProps } from "$app/components/NewProductPage";

function New() {
  const {
    current_seller_currency_code,
    native_product_types,
    service_product_types,
    release_at_date,
    show_orientation_text,
    eligible_for_service_products,
    ai_generation_enabled,
    ai_promo_dismissed,
  } = usePage<NewProductPageProps>().props;

  return (
    <NewProductPage
      current_seller_currency_code={current_seller_currency_code}
      native_product_types={native_product_types}
      service_product_types={service_product_types}
      release_at_date={release_at_date}
      show_orientation_text={show_orientation_text}
      eligible_for_service_products={eligible_for_service_products}
      ai_generation_enabled={ai_generation_enabled}
      ai_promo_dismissed={ai_promo_dismissed}
    />
  );
}

export default New;
