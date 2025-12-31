import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import AdminNav from "$app/components/Admin/Nav";
import AdminNewSalesReportPopover from "$app/components/Admin/SalesReports/NewSalesReportPopover";
import AdminSearchPopover from "$app/components/Admin/SearchPopover";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import Alert, { showAlert, type AlertPayload } from "$app/components/server-components/Alert";
import useRouteLoading from "$app/components/useRouteLoading";

type FlashData = {
  notice?: string;
  alert?: string;
  warning?: string;
};

type PageProps = {
  title: string;
};

// Convert Inertia flash data to AlertPayload format
const flashToAlertPayload = (flash: FlashData): AlertPayload | null => {
  if (flash.alert) return { message: flash.alert, status: "danger" };
  if (flash.warning) return { message: flash.warning, status: "warning" };
  if (flash.notice) return { message: flash.notice, status: "success" };
  return null;
};

const Admin = ({ children }: { children: React.ReactNode }) => {
  const page = usePage<PageProps>();
  const { title } = page.props;
  // Access flash from page.flash (not page.props.flash) - this data does NOT persist in history state
  const flash = (page as unknown as { flash: FlashData }).flash;
  const isRouteLoading = useRouteLoading();

  React.useEffect(() => {
    const alertPayload = flashToAlertPayload(flash || {});
    if (alertPayload) {
      showAlert(alertPayload.message, alertPayload.status === "danger" ? "error" : alertPayload.status);
    }
  }, [flash]);

  const initialAlert = flashToAlertPayload(flash || {});

  return (
    <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
      <Head title={title} />
      <Alert initial={initialAlert} />
      <AdminNav />
      <main className="flex h-screen flex-1 flex-col overflow-y-auto">
        <header className="flex items-center justify-between border-b border-border p-4 md:p-8">
          <h1>{title}</h1>
          <div className="actions grid flex-1 grid-cols-2 gap-2 has-[>*:only-child]:grid-cols-1 sm:flex sm:flex-none md:-my-2">
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
