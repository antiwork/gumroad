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

import { getCommunities } from "$app/data/communities";
import { buildStaticRouter, GlobalProps, register } from "$app/utils/serverComponentUtil";

import { CommunityView } from "./CommunityView";

const ErrorBoundary = () => {
  const error = useRouteError();
  return (
    <div>
      <div>
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

let abortController: AbortController | null = null;
const routes: RouteObject[] = [
  {
    path: "/communities/:sellerId?/:communityId?",
    element: <CommunityView />,
    errorElement: <ErrorBoundary />,
    loader: async ({ params }) => {
      abortController?.abort();
      abortController = new AbortController();
      const data = await getCommunities({ abortSignal: abortController.signal });
      return json({ ...data, selectedCommunityId: params.communityId }, { status: 200 });
    },
  },
];

const CommunitiesPage = () => {
  const router = createBrowserRouter(routes);

  return <RouterProvider router={router} />;
};

const CommunitiesRouter = async (global: GlobalProps) => {
  const { router, context } = await buildStaticRouter(global, routes);
  const component = () => <StaticRouterProvider router={router} context={context} nonce={global.csp_nonce} />;
  component.displayName = "CommunitiesRouter";
  return component;
};

export default register({ component: CommunitiesPage, ssrComponent: CommunitiesRouter, propParser: () => ({}) });
