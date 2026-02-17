import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";

type Props = {
  success: boolean;
  message: string;
};

function FollowersFromEmbedFormPage() {
  const { success, message } = cast<Props>(usePage().props);

  return (
    <div className="flex min-h-screen flex-col justify-between">
      <main className="stack single-page-form">
        <header>
          <h2>{success ? "Followed!" : "Something went wrong"}</h2>
          <p>{message}</p>
        </header>
      </main>
      <PoweredByFooter />
    </div>
  );
}

FollowersFromEmbedFormPage.loggedInUserLayout = true;
export default FollowersFromEmbedFormPage;
