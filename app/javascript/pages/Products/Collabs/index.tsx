import { usePage } from "@inertiajs/react";
import React from "react";

import CollabsPage from "$app/components/server-components/CollabsPage";

type CollabProductsPageProps = {
  memberships: any[];
  memberships_pagination: any;
  products: any[];
  products_pagination: any;
  stats: {
    total_revenue: number;
    total_customers: number;
    total_members: number;
    total_collaborations: number;
  };
  archived_tab_visible: boolean;
  collaborators_disabled_reason: string | null;
};

function Collabs() {
  const { collab_products_page_props } = usePage<{ collab_products_page_props: CollabProductsPageProps }>().props;

  return <CollabsPage {...collab_products_page_props} />;
}

export default Collabs;
