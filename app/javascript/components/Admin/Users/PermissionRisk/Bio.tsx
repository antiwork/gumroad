import React from "react";

import type { User } from "$app/components/Admin/Users/User";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";

type BioProps = {
  user: User;
};

const Bio = ({ user }: BioProps) => (
  <>
    <hr />
    <Details>
      <DetailsToggle>
        <h3>Bio</h3>
      </DetailsToggle>
      {user.bio ? (
        <div>{user.bio}</div>
      ) : (
        <Alert role="status" variant="info">
          No bio provided.
        </Alert>
      )}
    </Details>
  </>
);

export default Bio;
