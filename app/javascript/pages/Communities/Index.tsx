import { usePage } from "@inertiajs/react";
import * as React from "react";
import { createBrowserRouter, isRouteErrorResponse, RouteObject, RouterProvider, useRouteError } from "react-router-dom";
import { cast } from "ts-safe-cast";

import { Community, CommunityNotificationSettings } from "$app/data/communities";
import { Placeholder } from "$app/components/ui/Placeholder";

import { CommunitiesProvider } from "./CommunitiesContext";
import { CommunityView } from "./components/CommunityView";

type Props = {
  has_products: boolean;
  communities: Community[];
  notification_settings: CommunityNotificationSettings;
  selected_seller_id: string | null;
  selected_community_id: string | null;
};

const ErrorBoundary = () => {
  const error = useRouteError();
  return (
    <div>
      <div>
        <Placeholder>
          <p>
            {isRouteErrorResponse(error) && error.status === 404
              ? "The resource you're looking for doesn't exist."
              : "Something went wrong."}
          </p>
        </Placeholder>
      </div>
    </div>
  );
};

const routes: RouteObject[] = [
  {
    path: "/communities/:sellerId?/:communityId?",
    element: <CommunityView />,
    errorElement: <ErrorBoundary />,
  },
];

function CommunitiesIndex() {
  const props = cast<Props>(usePage().props);
  const router = React.useMemo(() => createBrowserRouter(routes), []);

  return (
    <CommunitiesProvider initialData={props}>
      <RouterProvider router={router} />
    </CommunitiesProvider>
  );
}

CommunitiesIndex.disableLayout = true;
export default CommunitiesIndex;
