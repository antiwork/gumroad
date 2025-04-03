import * as React from "react";

const pageNames = {
  widgets: "Widgets",
  ping: "Ping",
  api: "API",
};

export const Layout = ({
  currentPage,
  children,
}: {
  currentPage: keyof typeof pageNames;
  children?: React.ReactNode;
}) => (
  <main>
    <header>
      <h1>{pageNames[currentPage]}</h1>
      <div role="tablist">
        {Object.entries(pageNames).map(([page, name]) => (
          <a role="tab" aria-selected={page === currentPage} href={Routes[`${page}_path`]()} key={page}>
            {name}
          </a>
        ))}
      </div>
    </header>
    {children}
  </main>
);
