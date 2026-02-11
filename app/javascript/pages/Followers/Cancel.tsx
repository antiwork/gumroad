import * as React from "react";

import { PoweredByFooter } from "$app/components/PoweredByFooter";

function FollowersCancelPage() {
  return (
    <div className="flex min-h-screen flex-col justify-between">
      <main className="stack single-page-form">
        <header>
          <h2>You have been unsubscribed.</h2>
          <p>You will no longer get posts from this creator.</p>
        </header>
      </main>
      <PoweredByFooter />
    </div>
  );
}

FollowersCancelPage.loggedInUserLayout = true;
export default FollowersCancelPage;
