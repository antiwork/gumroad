import React from "react";

import { LoadingSpinner } from "$app/components/LoadingSpinner";

type AdminProductStatsViewCountProps = {
  viewsCount: number;
  isLoading: boolean;
};

const AdminProductStatsViewCount = ({ viewsCount, isLoading }: AdminProductStatsViewCountProps) => (
  <li>{isLoading ? <LoadingSpinner /> : `${viewsCount} views`}</li>
);

export default AdminProductStatsViewCount;
