import { usePage } from "@inertiajs/react";
import React from "react";

import { default as FormPage, FormPageProps } from "$app/components/CheckoutDashboard/FormPage";

function Form() {
  const { pages, user, cart_item, card_product, custom_fields, products } = usePage<FormPageProps>().props;

  return (
    <FormPage
      pages={pages}
      user={user}
      cart_item={cart_item}
      card_product={card_product}
      custom_fields={custom_fields}
      products={products}
    />
  );
}

export default Form;
