import * as React from "react";
import {
  isRouteErrorResponse,
  useRouteError,
  RouteObject,
  createBrowserRouter,
  RouterProvider,
  json,
} from "react-router-dom";
import { StaticRouterProvider } from "react-router-dom/server";

import { getEditUtmLink, getNewUtmLink, getUtmLinks, SortKey } from "$app/data/utm_links";
import { assertDefined } from "$app/utils/assert";
import { buildStaticRouter, GlobalProps, register } from "$app/utils/serverComponentUtil";

import { PageHeader } from "$app/components/ui/PageHeader";
import { Sort } from "$app/components/useSortingTableDriver";

import { UtmLinkForm } from "./UtmLinkForm";
import UtmLinkList from "./UtmLinkList";

export const UtmLinkLayout = ({
  title,
  actions,
  children,
}: {
  title: string;
  actions?: React.ReactNode;
  children: React.ReactNode;
}) => (
  <div>
    <PageHeader title={title} actions={actions} />
    {children}
  </div>
);

const ErrorBoundary = () => {
  const error = useRouteError();
  return (
    <div>
      <div className="p-4 md:p-8">
        <div className="placeholder">
          <p>
            {isRouteErrorResponse(error) && error.status === 404
              ? "The resource you're looking for doesn't exist."
              : "Something went wrong."}
          </p>
        </div>
      </div>
    </div>
  );
};

export const extractSortParam = (rawParams: URLSearchParams): Sort<SortKey> | null => {
  const column = rawParams.get("key");
  switch (column) {
    case "link":
    case "date":
    case "source":
    case "medium":
    case "campaign":
    case "clicks":
    case "sales_count":
    case "revenue_cents":
    case "conversion_rate":
      return {
        key: column,
        direction: rawParams.get("direction") === "desc" ? "desc" : "asc",
      };
    default:
      return null;
  }
};

const routes: RouteObject[] = [
  {
    path: "/dashboard/utm_links",
    element: <UtmLinkList />,
    errorElement: <ErrorBoundary />,
    loader: async ({ request }) => {
      const url = new URL(request.url);
      const query = url.searchParams.get("query") ?? null;
      const page = url.searchParams.get("page");
      const sort = extractSortParam(url.searchParams);
      const data = await getUtmLinks({
        query,
        page: page ? parseInt(page, 10) : 1,
        sort,
        abortSignal: request.signal,
      });
      return json(data, { status: 200 });
    },
  },
  {
    path: "/dashboard/utm_links/new",
    element: <UtmLinkForm />,
    loader: async ({ request }) => {
      const url = new URL(request.url);
      const copyFrom = url.searchParams.get("copy_from");
      const data = await getNewUtmLink({ abortSignal: request.signal, copyFrom });
      return json(data, { status: 200 });
    },
  },
  {
    path: "/dashboard/utm_links/:id/edit",
    element: <UtmLinkForm />,
    loader: async ({ params, request }) => {
      const data = await getEditUtmLink({
        id: assertDefined(params.id, "UTM Link ID is required"),
        abortSignal: request.signal,
      });
      return json(data, { status: 200 });
    },
  },
];

const UtmLinksPage = () => {
  const router = createBrowserRouter(routes);

  return <RouterProvider router={router} />;
};

const UtmLinksRouter = async (global: GlobalProps) => {
  const { router, context } = await buildStaticRouter(global, routes);
  const component = () => <StaticRouterProvider router={router} context={context} nonce={global.csp_nonce} />;
  component.displayName = "UtmLinksRouter";
  return component;
};

export default register({ component: UtmLinksPage, ssrComponent: UtmLinksRouter, propParser: () => ({}) });
