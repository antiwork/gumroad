import * as React from "react";

import { PoweredByFooter } from "$app/components/PoweredByFooter";

function FollowersFromEmbedFormPage() {
  return (
    <div className="flex min-h-screen flex-col justify-between">
      <main className="stack single-page-form">
        <header>
          <h2>Followed!</h2>
          <p>Check your inbox to confirm your follow request.</p>
        </header>
      </main>
      <PoweredByFooter />
    </div>
  );
}

FollowersFromEmbedFormPage.loggedInUserLayout = true;
export default FollowersFromEmbedFormPage;
