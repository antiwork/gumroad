import { usePage } from "@inertiajs/react";
import React from "react";

import { default as AffiliatedPage, AffiliatedPageProps } from "$app/components/AffiliatedPage";

function Affiliated() {
  const {
    pagination,
    affiliated_products,
    stats,
    global_affiliates_data,
    archived_tab_visible,
    affiliates_disabled_reason,
  } = usePage<AffiliatedPageProps>().props;

  return (
    <AffiliatedPage
      pagination={pagination}
      affiliated_products={affiliated_products}
      stats={stats}
      global_affiliates_data={global_affiliates_data}
      archived_tab_visible={archived_tab_visible}
      affiliates_disabled_reason={affiliates_disabled_reason}
    />
  );
}

export default Affiliated;
