import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import AdminNav from "$app/components/Admin/Nav";
import AdminNewSalesReportPopover from "$app/components/Admin/SalesReports/NewSalesReportPopover";
import AdminSearchPopover from "$app/components/Admin/SearchPopover";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import Alert, { type AlertPayload } from "$app/components/server-components/Alert";
import { useFlashMessage } from "$app/components/useFlashMessage";
import useRouteLoading from "$app/components/useRouteLoading";

type PageProps = {
  title: string;
  flash?: AlertPayload;
};

const Admin = ({ children }: { children: React.ReactNode }) => {
  const { title, flash } = usePage<PageProps>().props;
  const isRouteLoading = useRouteLoading();

  useFlashMessage(flash);

  return (
    <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
      <Head title={title} />
      <Alert initial={null} />
      <AdminNav />
      <main className="flex h-screen flex-1 flex-col overflow-y-auto">
        <header className="flex items-center justify-between border-b border-border p-4 md:p-8">
          <h1>{title}</h1>
          <div className="actions grid shrink-0 grid-cols-2 gap-2 has-[>*:only-child]:grid-cols-1 sm:flex md:-my-2">
            <AdminSearchPopover />
            {window.location.pathname === Routes.admin_sales_reports_path() ? <AdminNewSalesReportPopover /> : null}
          </div>
        </header>
        {isRouteLoading ? <LoadingSkeleton /> : null}
        <div className={classNames("p-4 md:p-8", { hidden: isRouteLoading })}>{children}</div>
      </main>
    </div>
  );
};

export default Admin;
