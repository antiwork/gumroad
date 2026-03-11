import React from "react";

import type { User } from "$app/components/Admin/Users/User";
import { Details, DetailsContent, DetailsToggle } from "$app/components/ui/Details";
import { Alert } from "$app/components/ui/Alert";

type BioProps = {
  user: User;
};

const Bio = ({ user }: BioProps) => (
  <>
    <hr />
    <Details>
      <DetailsToggle><h3>Bio</h3></DetailsToggle>
      <DetailsContent>
        {user.bio ? (
          <div>{user.bio}</div>
        ) : (
          <Alert role="status" variant="info">
            No bio provided.
          </Alert>
        )}
      </DetailsContent>
    </Details>
  </>
);

export default Bio;
