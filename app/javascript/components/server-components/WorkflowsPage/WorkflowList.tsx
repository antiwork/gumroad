import * as React from "react";
import { Link, useLoaderData } from "react-router-dom";
import { cast } from "ts-safe-cast";

import { Workflow, deleteWorkflow } from "$app/data/workflows";
import { formatStatNumber } from "$app/utils/formatStatNumber";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout } from "$app/components/server-components/WorkflowsPage";

import placeholder from "$assets/images/placeholders/workflows.png";

const WorkflowList = () => {
  const loggedInUser = useLoggedInUser();
  const { workflows: initialWorkflows } = cast<{ workflows: Workflow[] }>(useLoaderData());
  const [workflows, setWorkflows] = React.useState(initialWorkflows);
  const canManageWorkflow = !!loggedInUser?.policies.workflow.create;
  const newWorkflowButton = (
    <Link to="/workflows/new" className="button accent" inert={!canManageWorkflow}>
      New workflow
    </Link>
  );
  const [deletingWorkflow, setDeletingWorkflow] = React.useState<{
    id: string;
    name: string;
    state: "delete-confirmation" | "deleting";
  } | null>(null);

  return (
    <Layout title="Workflows" actions={newWorkflowButton}>
      {workflows.length > 0 ? (
        <div className="space-y-8 p-4 md:p-8">
          {workflows.map((workflow) => (
            <WorkflowRow
              key={workflow.external_id}
              workflow={workflow}
              canManageWorkflow={!!canManageWorkflow}
              onDelete={() =>
                setDeletingWorkflow({ id: workflow.external_id, name: workflow.name, state: "delete-confirmation" })
              }
            />
          ))}
          {deletingWorkflow ? (
            <Modal
              open
              allowClose={deletingWorkflow.state === "delete-confirmation"}
              onClose={() => setDeletingWorkflow(null)}
              title="Delete workflow?"
              footer={
                <>
                  <Button disabled={deletingWorkflow.state === "deleting"} onClick={() => setDeletingWorkflow(null)}>
                    Cancel
                  </Button>
                  {deletingWorkflow.state === "deleting" ? (
                    <Button color="danger" disabled>
                      Deleting...
                    </Button>
                  ) : (
                    <Button
                      color="danger"
                      onClick={asyncVoid(async () => {
                        try {
                          setDeletingWorkflow({ ...deletingWorkflow, state: "deleting" });
                          await deleteWorkflow(deletingWorkflow.id);
                          setWorkflows(workflows.filter((workflow) => workflow.external_id !== deletingWorkflow.id));
                          setDeletingWorkflow(null);
                          showAlert("Workflow deleted!", "success");
                        } catch (e) {
                          assertResponseError(e);
                          showAlert("Sorry, something went wrong. Please try again.", "error");
                        }
                      })}
                    >
                      Delete
                    </Button>
                  )}
                </>
              }
            >
              <h4>
                Are you sure you want to delete the workflow "{deletingWorkflow.name}"? This action cannot be undone.
              </h4>
            </Modal>
          ) : null}
        </div>
      ) : (
        <div className="p-4 md:p-8">
          <div className="placeholder">
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>Automate emails with ease.</h2>
            <h4>Workflows allow you to send scheduled emails to a subset of your audience based on a trigger.</h4>
            {newWorkflowButton}
            <a href="/help/article/131-using-workflows-to-send-automated-updates" target="_blank" rel="noreferrer">
              Learn more about workflows
            </a>
          </div>
        </div>
      )}
    </Layout>
  );
};

const WorkflowRow = ({
  workflow,
  canManageWorkflow,
  onDelete,
}: {
  workflow: Workflow;
  canManageWorkflow: boolean;
  onDelete: () => void;
}) => {
  const header = (
    <div style={{ display: "flex", alignItems: "center" }}>
      <h3 style={{ marginRight: "auto" }}>{workflow.name}</h3>
      <div style={{ display: "flex", gap: "var(--spacer-4)", alignItems: "center" }}>
        {workflow.published ? <small>Published</small> : <small>Unpublished</small>}
        <div className="button-group">
          <Link
            className="button"
            to={`/workflows/${workflow.external_id}/edit`}
            aria-label="Edit workflow"
            inert={!canManageWorkflow}
          >
            <Icon name="pencil" />
          </Link>
          <Button color="danger" outline aria-label="Delete workflow" disabled={!canManageWorkflow} onClick={onDelete}>
            <Icon name="trash2" />
          </Button>
        </div>
      </div>
    </div>
  );

  return workflow.installments.length > 0 ? (
    <table key={workflow.external_id}>
      <caption>{header}</caption>
      <thead>
        <tr>
          <th style={workflow.published ? { width: "40%" } : undefined}>Email</th>
          {workflow.published ? (
            <>
              <th>Delay</th>
              <th>Sent</th>
              <th>Opens</th>
              <th>Clicks</th>
            </>
          ) : null}
        </tr>
      </thead>
      <tbody>
        {workflow.installments.map((installment) => (
          <tr key={installment.external_id}>
            <td data-label="Email">{installment.name}</td>
            {workflow.published ? (
              <>
                <td data-label="Delay">
                  {installment.delayed_delivery_time_duration} {installment.displayed_delayed_delivery_time_period}
                </td>
                <td data-label="Sent" style={{ whiteSpace: "nowrap" }}>
                  {formatStatNumber({ value: installment.sent_count ?? 0 })}
                </td>
                <td data-label="Opens" style={{ whiteSpace: "nowrap" }}>
                  {`${formatStatNumber({ value: installment.open_rate ?? 0 })}%`}
                </td>
                <td data-label="Clicks" style={{ whiteSpace: "nowrap" }}>
                  {formatStatNumber({ value: installment.click_count })}
                </td>
              </>
            ) : null}
          </tr>
        ))}
      </tbody>
    </table>
  ) : (
    <section className="paragraphs" key={workflow.external_id}>
      {header}
      <div className="placeholder">
        <h4>
          <>
            No emails yet,{" "}
            <Link to={`/workflows/${workflow.external_id}/emails`} inert={!canManageWorkflow}>
              add one
            </Link>
          </>
        </h4>
      </div>
    </section>
  );
};

export default WorkflowList;
