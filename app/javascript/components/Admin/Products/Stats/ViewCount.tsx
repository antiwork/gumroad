import React from "react";

import Loading from "$app/components/Admin/Loading";

type AdminProductStatsViewCountProps = {
  viewsCount: number;
  isLoading: boolean;
};

const AdminProductStatsViewCount = ({ viewsCount, isLoading }: AdminProductStatsViewCountProps) => (
  <li>{isLoading ? <Loading /> : `${viewsCount} views`}</li>
);

export default AdminProductStatsViewCount;
