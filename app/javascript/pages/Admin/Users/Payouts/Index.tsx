import { usePage, router } from "@inertiajs/react";
import React from "react";

import AdminEmptyState from "$app/components/Admin/EmptyState";
import AdminPayouts from "$app/components/Admin/Payouts";
import { type Payout } from "$app/components/Admin/Payouts/Payout";
import { Pagination, PaginationProps } from "$app/components/Pagination";

type PageProps = {
  payouts: Payout[];
  pagination: PaginationProps;
};

const Index = () => {
  const { payouts, pagination } = usePage<PageProps>().props;

  const onChangePage = (page: number) => {
    router.reload({ data: { page: page.toString() } });
  };

  if (payouts.length === 0 && pagination.page === 1) {
    return <AdminEmptyState message="No payouts found." />;
  }

  return (
    <div className="flex flex-col gap-4">
      <AdminPayouts payouts={payouts} />
      {pagination.pages > 1 && <Pagination pagination={pagination} onChangePage={onChangePage} />}
    </div>
  );
};

export default Index;
