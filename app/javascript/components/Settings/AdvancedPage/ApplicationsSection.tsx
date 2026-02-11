import { Link, router } from "@inertiajs/react";
import placeholderAppIcon from "images/gumroad_app.png";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import ApplicationForm from "$app/components/Settings/AdvancedPage/ApplicationForm";
import { FormSection } from "$app/components/ui/FormSection";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";

export type Application = {
  id: string;
  name: string;
  icon_url: string | null;
};

const CreateApplication = () => (
  <>
    <h3>Create application</h3>
    <ApplicationForm />
  </>
);

const ApplicationList = (props: { applications: Application[] }) => {
  const [applications, setApplications] = React.useState(props.applications);

  const removeApplication = (id: string) => () => {
    setApplications((prevState) => prevState.filter((app) => app.id !== id));
  };

  return applications.length > 0 ? (
    <>
      <h3>Your applications</h3>
      <Rows role="list">
        {applications.map((app) => (
          <ApplicationRow key={app.id} application={app} onRemove={removeApplication(app.id)} />
        ))}
      </Rows>
    </>
  ) : null;
};

const ApplicationRow = ({ application, onRemove }: { application: Application; onRemove: () => void }) => {
  const [deleteConfirmation, setDeleteConfirmation] = React.useState<{
    state: "delete-confirmation" | "deleting";
  } | null>(null);

  const deleteApp = () => {
    setDeleteConfirmation({ state: "deleting" });
    router.delete(Routes.oauth_application_path(application.id), {
      preserveScroll: true,
      onSuccess: () => {
        setDeleteConfirmation(null);
        showAlert("Application deleted.", "success");
        onRemove(); // This will update the local state immediately
      },
      onError: () => {
        setDeleteConfirmation({ state: "delete-confirmation" });
        showAlert("Failed to delete app.", "error");
      },
    });
  };

  return (
    <Row role="listitem">
      <RowContent>
        <img src={application.icon_url || placeholderAppIcon} width={56} height={56} />
        <h4>{application.name}</h4>
      </RowContent>
      <RowActions>
        <Button>
          <Link className="no-underline" href={Routes.oauth_application_path(application.id)}>
            Edit
          </Link>
        </Button>
        <Button color="danger" onClick={() => setDeleteConfirmation({ state: "delete-confirmation" })}>
          Delete
        </Button>
      </RowActions>
      {deleteConfirmation ? (
        <Modal
          open
          allowClose={deleteConfirmation.state === "delete-confirmation"}
          onClose={() => setDeleteConfirmation(null)}
          title="Delete application"
          footer={
            <>
              <Button disabled={deleteConfirmation.state === "deleting"} onClick={() => setDeleteConfirmation(null)}>
                Cancel
              </Button>
              <Button color="danger" disabled={deleteConfirmation.state === "deleting"} onClick={deleteApp}>
                {deleteConfirmation.state === "deleting" ? "Deleting..." : "Delete"}
              </Button>
            </>
          }
        >
          <h4>Are you sure you want to delete {application.name}? This action cannot be undone.</h4>
        </Modal>
      ) : null}
    </Row>
  );
};

const ApplicationsSection = (props: { applications: Application[] }) => (
  <FormSection
    header={
      <>
        <h2>Applications</h2>
        <a href="/help/article/280-create-application-api" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </>
    }
  >
    <CreateApplication />
    <ApplicationList applications={props.applications} />
  </FormSection>
);
export default ApplicationsSection;
