import { usePage } from "@inertiajs/react";
import React from "react";

import { default as CollabsPage, CollabsPageProps } from "$app/components/CollabsPage";

function Collabs() {
  const {
    memberships,
    memberships_pagination,
    products,
    products_pagination,
    stats,
    archived_tab_visible,
    collaborators_disabled_reason,
  } = usePage<CollabsPageProps>().props;

  return (
    <CollabsPage
      memberships={memberships}
      memberships_pagination={memberships_pagination}
      products={products}
      products_pagination={products_pagination}
      stats={stats}
      archived_tab_visible={archived_tab_visible}
      collaborators_disabled_reason={collaborators_disabled_reason}
    />
  );
}

export default Collabs;
