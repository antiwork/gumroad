import * as React from "react";

export const InvalidNameForEmailDeliveryWarning: React.FC = () => (
  <div role="alert" className="warning">
    <div>
      Your name contains a colon (:) which causes email delivery problems and will be removed from the sender name when
      emails are sent. <a href={Routes.settings_profile_path()}>Update your name</a> to fix this.
    </div>
  </div>
);
