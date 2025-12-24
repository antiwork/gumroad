import { Link, router } from "@inertiajs/react";
import placeholderAppIcon from "images/gumroad_app.png";
import * as React from "react";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import ApplicationForm from "$app/components/Settings/AdvancedPage/ApplicationForm";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";

export type Application = {
  id: string;
  name: string;
  icon_url: string | null;
};

const CreateApplication = () => (
  <>
    <header id="application-form">
      <h2>Applications</h2>
      <a href="/help/article/280-create-application-api" target="_blank" rel="noreferrer">
        Learn more
      </a>
    </header>
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
  const deleteApp = () => {
    // eslint-disable-next-line no-alert
    if (!confirm("Delete this application forever?")) return;

    router.delete(Routes.oauth_application_path(application.id), {
      preserveScroll: true,
      onSuccess: () => {
        showAlert("Application deleted.", "success");
        onRemove(); // This will update the local state immediately
      },
      onError: () => {
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
        <Button color="danger" onClick={deleteApp}>
          Delete
        </Button>
      </RowActions>
    </Row>
  );
};

const ApplicationsSection = (props: { applications: Application[] }) => (
  <section className="p-4! md:p-8!">
    <CreateApplication />
    <ApplicationList applications={props.applications} />
  </section>
);
export default ApplicationsSection;
