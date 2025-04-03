import * as React from "react";
import {
  RouterProvider,
  createBrowserRouter,
  json,
  Link,
  RouteObject,
  useLocation,
  useRouteError,
  isRouteErrorResponse,
} from "react-router-dom";
import { StaticRouterProvider } from "react-router-dom/server";

import { getNewWorkflow, getWorkflows, getEditWorkflow, SaveActionName } from "$app/data/workflows";
import { assertDefined } from "$app/utils/assert";
import { buildStaticRouter, GlobalProps, register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import WorkflowEmails from "$app/components/server-components/WorkflowsPage/WorkflowEmails";
import WorkflowForm, { WorkflowTrigger } from "$app/components/server-components/WorkflowsPage/WorkflowForm";
import WorkflowList from "$app/components/server-components/WorkflowsPage/WorkflowList";
import { Toggle } from "$app/components/Toggle";

type LayoutProps = {
  title: string;
  actions?: React.ReactNode;
  navigation?: React.ReactNode;
  children: React.ReactNode;
  preview?: React.ReactNode;
};

export const Layout = ({ title, actions, navigation, children, preview }: LayoutProps) => {
  const { pathname } = useLocation();
  const [pageLoaded, setPageLoaded] = React.useState(false);

  React.useEffect(() => {
    const bodyClassList = document.querySelector("body")?.classList;
    if (bodyClassList) bodyClassList[preview ? "add" : "remove"]("fixed-aside");

    setPageLoaded(true);
  }, [pathname]);

  if (!pageLoaded) return null;

  return (
    <>
      <header className="sticky-top">
        <h1>{title}</h1>
        {actions ? <div className="actions">{actions}</div> : null}
        {navigation ?? null}
      </header>
      <main>{children}</main>
      {preview ? <aside aria-label="Preview">{preview}</aside> : null}
    </>
  );
};

type PublishButtonProps = {
  isPublished: boolean;
  wasPublishedPreviously: boolean;
  isDisabled: boolean;
  sendToPastCustomers: {
    enabled: boolean;
    toggle: (value: boolean) => void;
    label: string;
  } | null;
  onClick: (saveActionName: SaveActionName) => void;
};

export const PublishButton = ({
  isPublished,
  wasPublishedPreviously,
  isDisabled,
  sendToPastCustomers,
  onClick,
}: PublishButtonProps) => {
  const [popoverOpen, setPopoverOpen] = React.useState(false);

  return isPublished ? (
    <Button onClick={() => onClick("save_and_unpublish")} disabled={isDisabled}>
      Unpublish
    </Button>
  ) : wasPublishedPreviously || sendToPastCustomers === null ? (
    <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
      Publish
    </Button>
  ) : (
    <Popover
      disabled={isDisabled}
      trigger={
        <div className="button" color="accent">
          Publish
          <Icon name="outline-cheveron-down" />
        </div>
      }
      open={popoverOpen}
      onToggle={setPopoverOpen}
    >
      <fieldset>
        <Button color="accent" onClick={() => onClick("save_and_publish")} disabled={isDisabled}>
          Publish now
        </Button>
        <Toggle value={sendToPastCustomers.enabled} onChange={sendToPastCustomers.toggle}>
          {sendToPastCustomers.label}
        </Toggle>
      </fieldset>
    </Popover>
  );
};

export const sendToPastCustomersCheckboxLabel = (workflowTrigger: WorkflowTrigger) =>
  workflowTrigger === "new_subscriber"
    ? "Also send to past email subscribers"
    : workflowTrigger === "member_cancels"
      ? "Also send to past members who canceled"
      : workflowTrigger === "new_affiliate"
        ? "Also send to past affiliates"
        : "Also send to past customers";

export const EditPageNavigation = (props: { workflowExternalId: string }) => {
  const { pathname } = useLocation();

  return (
    <div role="tablist">
      <Link
        to={`/workflows/${props.workflowExternalId}/edit`}
        role="tab"
        aria-selected={pathname === `/workflows/${props.workflowExternalId}/edit`}
      >
        Details
      </Link>
      <Link
        to={`/workflows/${props.workflowExternalId}/emails`}
        role="tab"
        aria-selected={pathname === `/workflows/${props.workflowExternalId}/emails`}
      >
        Emails
      </Link>
    </div>
  );
};

const ErrorBoundary = () => {
  const error = useRouteError();
  return (
    <main>
      <div>
        <div className="placeholder">
          <p>
            {isRouteErrorResponse(error) && error.status === 404
              ? "The resource you're looking for doesn't exist."
              : "Something went wrong."}
          </p>
        </div>
      </div>
    </main>
  );
};

const routes: RouteObject[] = [
  {
    path: "/workflows",
    element: <WorkflowList />,
    loader: async () => json(await getWorkflows(), { status: 200 }),
  },
  {
    path: "/workflows/new",
    element: <WorkflowForm />,
    loader: async () => json(await getNewWorkflow(), { status: 200 }),
  },
  {
    path: "/workflows/:id/edit",
    element: <WorkflowForm />,
    errorElement: <ErrorBoundary />,
    loader: async ({ params }) => {
      const response = await getEditWorkflow(assertDefined(params.id, "Workflow ID is required"));
      return response.success ? json(response) : new Response("", { status: response.status });
    },
  },
  {
    path: "/workflows/:id/emails",
    element: <WorkflowEmails />,
    errorElement: <ErrorBoundary />,
    loader: async ({ params }) => {
      const response = await getEditWorkflow(assertDefined(params.id, "Workflow ID is required"));
      return response.success ? json(response) : new Response("", { status: response.status });
    },
  },
];

const WorkflowsPage = () => {
  const router = createBrowserRouter(routes);

  return <RouterProvider router={router} />;
};

const WorkflowsRouter = async (global: GlobalProps) => {
  const { router, context } = await buildStaticRouter(global, routes);
  const component = () => <StaticRouterProvider router={router} context={context} nonce={global.csp_nonce} />;
  component.displayName = "WorkflowsRouter";
  return component;
};

export default register({ component: WorkflowsPage, ssrComponent: WorkflowsRouter, propParser: () => ({}) });
