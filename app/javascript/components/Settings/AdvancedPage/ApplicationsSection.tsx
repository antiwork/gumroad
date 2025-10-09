import placeholderAppIcon from "images/gumroad_app.png";
import * as React from "react";

import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Application } from "$app/components/server-components/Settings/AdvancedPage";
import ApplicationForm from "$app/components/Settings/AdvancedPage/ApplicationForm";

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
      <div className="rows" role="list">
        {applications.map((app) => (
          <ApplicationRow key={app.id} application={app} onRemove={removeApplication(app.id)} />
        ))}
      </div>
    </>
  ) : null;
};

const ApplicationRow = ({ application, onRemove }: { application: Application; onRemove: () => void }) => {
  const deleteApp = asyncVoid(async () => {
    // eslint-disable-next-line no-alert
    if (!confirm("Delete this application forever?")) return;

    try {
      const response = await request({
        url: Routes.oauth_application_path(application.id),
        method: "DELETE",
        accept: "json",
      });
      if (!response.ok) throw new ResponseError();
      showAlert("Application deleted.", "success");
      onRemove();
    } catch (e) {
      assertResponseError(e);
      showAlert("Failed to delete app.", "error");
    }
  });

  return (
    <div role="listitem">
      <div className="content">
        <img src={application.icon_url || placeholderAppIcon} width={56} height={56} />
        <h4>{application.name}</h4>
      </div>
      <div className="actions">
        <NavigationButton href={Routes.oauth_application_path(application.id)}>Edit</NavigationButton>
        <Button outline color="danger" onClick={deleteApp}>
          Delete
        </Button>
      </div>
    </div>
  );
};

const ApplicationsSection = (props: { applications: Application[] }) => (
  <section className="p-4! md:p-8!">
    <CreateApplication />
    <ApplicationList applications={props.applications} />
  </section>
);
export default ApplicationsSection;
