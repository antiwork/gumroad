import { Link } from "@inertiajs/react";
import React from "react";

import { TabButton, TabButtons } from "$app/components/ui/TabButtons";

type Props = {
  selectedTab: string;
  userId: number;
  isAffiliateUser?: boolean;
};

const AdminUserAndProductsTabs = ({ selectedTab, userId, isAffiliateUser = false }: Props) => (
  <TabButtons>
    <TabButton isSelected={selectedTab === "profile"} asChild>
      <Link
        href={isAffiliateUser ? Routes.admin_affiliate_path(userId) : Routes.admin_user_path(userId)}
        prefetch
        className="no-underline"
      >
        Profile
      </Link>
    </TabButton>
    <TabButton isSelected={selectedTab === "products"} asChild>
      <Link
        href={isAffiliateUser ? Routes.admin_affiliate_products_path(userId) : Routes.admin_user_products_path(userId)}
        prefetch
        className="no-underline"
      >
        Products
      </Link>
    </TabButton>
  </TabButtons>
);

export default AdminUserAndProductsTabs;
