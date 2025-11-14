import { Link, router } from "@inertiajs/react";
import * as React from "react";

import { Workflow } from "$app/types/workflow";
import { formatStatNumber } from "$app/utils/formatStatNumber";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import Placeholder from "$app/components/ui/Placeholder";
import { Layout } from "$app/components/WorkflowsPage";

import placeholder from "$assets/images/placeholders/workflows.png";

type WorkflowListProps = {
  workflows: Workflow[];
};

const WorkflowList = ({ workflows }: WorkflowListProps) => {
  const loggedInUser = useLoggedInUser();
  const canManageWorkflow = !!loggedInUser?.policies.workflow.create;
  const newWorkflowButton = (
    <Link href={Routes.new_workflow_path()} className="button accent" inert={!canManageWorkflow || undefined}>
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
                      onClick={() => {
                        setDeletingWorkflow({ ...deletingWorkflow, state: "deleting" });
                        router.delete(Routes.workflow_path(deletingWorkflow.id), {
                          only: ["workflows", "flash"],
                          onSuccess: () => {
                            setDeletingWorkflow(null);
                          },
                          onError: () => {
                            setDeletingWorkflow((previous) =>
                              previous ? { ...previous, state: "delete-confirmation" } : previous,
                            );
                            showAlert("Sorry, something went wrong. Please try again.", "error");
                          },
                        });
                      }}
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
          <Placeholder>
            <figure>
              <img src={placeholder} />
            </figure>
            <h2>Automate emails with ease.</h2>
            <h4>Workflows allow you to send scheduled emails to a subset of your audience based on a trigger.</h4>
            {newWorkflowButton}
            <a href="/help/article/131-using-workflows-to-send-automated-updates" target="_blank" rel="noreferrer">
              Learn more about workflows
            </a>
          </Placeholder>
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
    <div className="flex items-center">
      <h3 style={{ marginRight: "auto" }}>{workflow.name}</h3>
      <div style={{ display: "flex", gap: "var(--spacer-4)", alignItems: "center" }}>
        {workflow.published ? <small>Published</small> : <small>Unpublished</small>}
        <div className="button-group">
          <Link
            className="button"
            href={Routes.edit_workflow_path(workflow.external_id)}
            aria-label="Edit workflow"
            inert={!canManageWorkflow || undefined}
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
      <Placeholder>
        <h4>
          No emails yet,{" "}
          <Link href={Routes.workflow_emails_path(workflow.external_id)} inert={!canManageWorkflow || undefined}>
            add one
          </Link>
        </h4>
      </Placeholder>
    </section>
  );
};

export default WorkflowList;
