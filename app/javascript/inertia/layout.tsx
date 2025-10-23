import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import { Nav } from "$app/components/client-components/Nav";
import { useClientAlert, ClientAlert, type AlertPayload } from "$app/components/ClientAlertProvider";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import useRouteLoading from "$app/components/useRouteLoading";

type PageProps = {
  title: string;
  flash?: AlertPayload;
};

export default function Layout({ children }: { children: React.ReactNode }) {
  const { title, flash } = usePage<PageProps>().props;
  const isRouteLoading = useRouteLoading();
  const { alert, showAlert } = useClientAlert();

  React.useEffect(() => {
    if (flash?.message) {
      showAlert(flash.message, flash.status);
    }
  }, [flash, showAlert]);

  return (
    <>
      <Head title={title} />
      <ClientAlert alert={alert} />
      <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
        <Nav title="Dashboard" />
        {isRouteLoading ? <LoadingSkeleton /> : null}
        <main className={classNames("flex-1 overflow-y-auto", { hidden: isRouteLoading })}>{children}</main>
      </div>
    </>
  );
}
