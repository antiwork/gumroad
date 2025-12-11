import { Link } from "@inertiajs/react";
import React from "react";

import { Tab, Tabs } from "$app/components/ui/Tabs";

type Props = {
  selectedTab: string;
  userId: number;
  isAffiliateUser?: boolean;
};

const AdminUserAndProductsTabs = ({ selectedTab, userId, isAffiliateUser = false }: Props) => (
  <Tabs variant="buttons">
    <Tab isSelected={selectedTab === "profile"} asChild>
      <Link href={isAffiliateUser ? Routes.admin_affiliate_path(userId) : Routes.admin_user_path(userId)} prefetch>
        Profile
      </Link>
    </Tab>
    <Tab isSelected={selectedTab === "products"} asChild>
      <Link
        href={isAffiliateUser ? Routes.admin_affiliate_products_path(userId) : Routes.admin_user_products_path(userId)}
        prefetch
      >
        Products
      </Link>
    </Tab>
  </Tabs>
);

export default AdminUserAndProductsTabs;
