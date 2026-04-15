import * as React from "react";

import { Alert } from "$app/components/ui/Alert";

export const InvalidNameForEmailDeliveryWarning: React.FC = () => (
  <Alert variant="warning">
    Your name contains a colon (:) which causes email delivery problems and will be removed from the sender name when
    emails are sent. <a href={Routes.settings_profile_path()}>Update your name</a> to fix this.
  </Alert>
);
