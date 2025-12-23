import React from "react";

import type { User } from "$app/components/Admin/Users/User";
import { Alert } from "$app/components/ui/Alert";

type BioProps = {
  user: User;
};

const Bio = ({ user }: BioProps) => (
  <>
    <hr />
    <details>
      <summary>
        <h3>Bio</h3>
      </summary>
      {user.bio ? (
        <div>{user.bio}</div>
      ) : (
        <Alert role="status" variant="info">
          No bio provided.
        </Alert>
      )}
    </details>
  </>
);

export default Bio;
