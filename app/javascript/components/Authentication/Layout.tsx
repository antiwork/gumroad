import * as React from "react";

import { useDomains } from "$app/components/DomainSettings";
import { PageHeader } from "$app/components/ui/PageHeader";

export const Layout = ({
  children,
  header,
  headerActions,
}: {
  children: React.ReactNode;
  header: React.ReactNode;
  headerActions?: React.ReactNode;
}) => {
  const { rootDomain, scheme } = useDomains();

  return (
    <div className="min-h-screen w-full flex items-center justify-center bg-slate-100 relative overflow-hidden text-slate-900">
      <div className="absolute top-[-10%] left-[-10%] w-[50%] h-[50%] bg-blue-100 rounded-full blur-[120px] opacity-60"></div>
      <div className="absolute bottom-[-10%] right-[-10%] w-[50%] h-[50%] bg-purple-100 rounded-full blur-[120px] opacity-60"></div>
      <div className="absolute inset-0 opacity-[0.1] bg-grid"></div>
      <div className="relative z-10 w-full max-w-md p-4">
        <div className="glass-card shadow-[0_20px_50px_rgba(0,0,0,0.1)] rounded-[2.5rem] overflow-hidden p-8 md:p-12">
          <PageHeader
            title={<a href={`${scheme}://${rootDomain}`} className="logo-full" aria-label="Gumroad" />}
            actions={headerActions}
            className="hidden p-8 sm:p-16"
          >
            {header}
          </PageHeader>
          <div className="flex flex-col items-center mb-10 text-center">
            <h1 className="text-3xl font-extrabold tracking-tight bg-clip-text text-transparent bg-gradient-to-r from-blue-700 to-indigo-700">
              SÀN AI
            </h1>
            <p className="text-slate-500 text-sm mt-2 font-medium">{header}</p>
          </div>
          <div>{children}</div>
        </div>
      </div>
    </div>
  );
};
