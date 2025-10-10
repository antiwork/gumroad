import { Head, usePage } from "@inertiajs/react";
import React from "react";

import { classNames } from "$app/utils/classNames";

import { Nav } from "$app/components/client-components/Nav";
import { useClientAlert, ClientAlert } from "$app/components/ClientAlertProvider";
import LoadingSkeleton from "$app/components/LoadingSkeleton";
import useRouteLoading from "$app/components/useRouteLoading";

export default function Layout({ children }: { children: React.ReactNode }) {
  const isRouteLoading = useRouteLoading();
  const { alert, isVisible } = useClientAlert();
  const { props } = usePage();

  return (
    <>
      <Head title={props.title?.toString() ?? "Gumroad"} />
      <ClientAlert alert={alert} isVisible={isVisible} />
      <div id="inertia-shell" className="flex h-screen flex-col lg:flex-row">
        <Nav title="Dashboard" />
        {isRouteLoading ? <LoadingSkeleton /> : null}
        <main className={classNames("flex-1 overflow-y-auto", { hidden: isRouteLoading })}>{children}</main>
      </div>
    </>
  );
}
