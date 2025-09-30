import { usePage } from "@inertiajs/react";
import React from "react";

import { default as CustomersPage, CustomerPageProps } from "$app/components/Audience/CustomersPage";

function index() {
  const {
    customers,
    pagination,
    product_id,
    products,
    count,
    currency_type,
    countries,
    can_ping,
    show_refund_fee_notice,
  } = usePage<CustomerPageProps>().props;

  return (
    <CustomersPage
      customers={customers}
      pagination={pagination}
      product_id={product_id}
      products={products}
      count={count}
      currency_type={currency_type}
      countries={countries}
      can_ping={can_ping}
      show_refund_fee_notice={show_refund_fee_notice}
    />
  );
}

export default index;
