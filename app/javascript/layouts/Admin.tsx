import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import AdminNav from "$app/components/Admin/Nav";
import AdminSearchPopover from "$app/components/Admin/SearchPopover";
import { ClientAlert, useClientAlert, type AlertPayload } from "$app/components/ClientAlertProvider";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import useRouteLoading from "$app/components/useRouteLoading";

type PageProps = {
  title: string;
  flash?: AlertPayload;
};

const Admin = ({ children }: { children: React.ReactNode }) => {
  const { title, flash } = usePage<PageProps>().props;
  const isRouteLoading = useRouteLoading();
  const { alert, showAlert } = useClientAlert();

  React.useEffect(() => {
    if (flash?.message) {
      showAlert(flash.message, flash.status);
    }
  }, [flash]);

  return (
    <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
      <Head title={title} />
      <ClientAlert alert={alert} />
      <AdminNav />
      <main className="flex h-screen flex-1 flex-col overflow-y-auto">
        <header className="flex items-center justify-between border-b border-border p-4 md:p-8">
          <h1>{title}</h1>
          <div className="actions">
            <AdminSearchPopover />
          </div>
        </header>
        {isRouteLoading ? <LoadingSkeleton /> : null}
        <div className={classNames("p-4 md:p-8", { hidden: isRouteLoading })}>{children}</div>
      </main>
    </div>
  );
};

export default Admin;
