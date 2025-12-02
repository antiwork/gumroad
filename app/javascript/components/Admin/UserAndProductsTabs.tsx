import { Link } from "@inertiajs/react";
import React from "react";

import { Tab, Tabs } from "$app/components/ui/Tabs";

type Props = {
  selectedTab: string;
  userExternalId: string;
  isAffiliateUser?: boolean;
};

const AdminUserAndProductsTabs = ({ selectedTab, userExternalId, isAffiliateUser = false }: Props) => (
  <Tabs variant="buttons">
    <Tab isSelected={selectedTab === "profile"} asChild>
      <Link
        href={isAffiliateUser ? Routes.admin_affiliate_path(userExternalId) : Routes.admin_user_path(userExternalId)}
        prefetch
      >
        Profile
      </Link>
    </Tab>
    <Tab isSelected={selectedTab === "products"} asChild>
      <Link
        href={
          isAffiliateUser
            ? Routes.admin_affiliate_products_path(userExternalId)
            : Routes.admin_user_products_path(userExternalId)
        }
        prefetch
      >
        Products
      </Link>
    </Tab>
  </Tabs>
);

export default AdminUserAndProductsTabs;
