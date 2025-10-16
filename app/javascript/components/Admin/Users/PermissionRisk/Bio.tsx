import React from "react";

import type { User } from "$app/components/Admin/Users/User";

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
        <div className="info" role="status">
          No bio provided.
        </div>
      )}
    </details>
  </>
);

export default Bio;
