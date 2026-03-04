import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";

type Props = {
  success: boolean;
  message: string;
};

function FollowersFromEmbedFormPage() {
  const { success, message } = cast<Props>(usePage().props);

  return (
    <div className="flex min-h-screen flex-col justify-between">
      <Card asChild>
        <main className="mx-auto my-4 h-min max-w-md w-[calc(100%-2rem)]">
          <CardContent asChild>
            <header className="flex-col items-stretch text-center">
              <h2>{success ? "Followed!" : "Something went wrong"}</h2>
              <p>{message}</p>
            </header>
          </CardContent>
        </main>
      </Card>
      <PoweredByFooter />
    </div>
  );
}

FollowersFromEmbedFormPage.loggedInUserLayout = true;
export default FollowersFromEmbedFormPage;
