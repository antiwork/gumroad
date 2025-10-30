import { usePage, router } from "@inertiajs/react";
import React from "react";

import { type Pagination as PaginationProps } from "$app/hooks/useLazyFetch";

import AdminEmptyState from "$app/components/Admin/EmptyState";
import AdminPayouts from "$app/components/Admin/Payouts";
import { type Payout } from "$app/components/Admin/Payouts/Payout";
import { Pagination } from "$app/components/Pagination";

type PageProps = {
  user: { id: number };
  payouts: Payout[];
  pagination: PaginationProps;
};

const Index = () => {
  const { user, payouts, pagination } = usePage<PageProps>().props;

  const paginationProps = {
    pages: Math.ceil(pagination.count ?? 0 / pagination.limit),
    page: pagination.page,
  };

  const onChangePage = (page: number) => {
    const params = new URLSearchParams(window.location.search);
    params.set("page", page.toString());
    router.visit(Routes.admin_user_payouts_path(user.id), {
      data: Object.fromEntries(params),
    });
  };

  if (payouts.length === 0 && pagination.page === 1) {
    return <AdminEmptyState message="No payouts found." />;
  }

  return (
    <div className="paragraphs">
      <AdminPayouts payouts={payouts} />
      {paginationProps.pages > 1 && <Pagination pagination={paginationProps} onChangePage={onChangePage} />}
    </div>
  );
};

export default Index;
