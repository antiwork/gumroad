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
    <div className="flex flex-1 flex-col justify-between p-4">
      <Card asChild>
        <main className="mx-auto h-min w-full max-w-md">
          <CardContent asChild>
            <header className="text-center">
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
