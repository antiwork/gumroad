import { Link } from "@inertiajs/react";
import React from "react";

import { type User as UserType } from "$app/components/Admin/Users/User";
import Tab from "$app/components/Tabs/Tab";
import TabList from "$app/components/Tabs/TabList";

type Props = {
  selectedTab: string;
  user: UserType;
};

const AdminUserAndProductsTabs = ({ selectedTab, user}: Props) => {
  return (
    <TabList>
      <Tab isSelected={selectedTab === "users"}>
        <Link href={Routes.admin_user_path(user.id)} className="block p-3 no-underline">
          Profile
        </Link>
      </Tab>
      <Tab isSelected={selectedTab === "products"}>
        <Link href={Routes.admin_user_products_path(user.id)} prefetch className="block p-3 no-underline">
          Products
        </Link>
      </Tab>
    </TabList>
  );
};

export default AdminUserAndProductsTabs;
