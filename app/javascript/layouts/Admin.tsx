import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import AdminNav from "$app/components/Admin/Nav";
import AdminSearchPopover from "$app/components/Admin/SearchPopover";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import useRouteLoading from "$app/components/useRouteLoading";

type PageProps = {
  title: string;
};

const Admin = ({ children }: { children: React.ReactNode }) => {
  const { title } = usePage<PageProps>().props;
  const isRouteLoading = useRouteLoading();
  return (
    <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
      <Head title={title} />

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
