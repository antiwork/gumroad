import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { NavigationButton } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";

type Props = {
  success: boolean;
  message: string;
  // Present when the subscribe couldn't be accepted from the embed form and the
  // visitor has to finish it on the seller's own Gumroad page, which renders a
  // CAPTCHA. Absent on every other outcome.
  subscribe_url?: string | null;
};

function FollowersFromEmbedFormPage() {
  const { success, message, subscribe_url } = typia.assert<Props>(usePage().props);

  return (
    <div className="flex flex-1 flex-col justify-between p-4">
      <Card asChild>
        <main className="mx-auto h-min w-full max-w-md">
          <CardContent asChild>
            <header className="text-center">
              <h2>{success ? "Followed!" : "Something went wrong"}</h2>
              <p>{message}</p>
              {subscribe_url != null ? (
                <NavigationButton color="primary" href={subscribe_url}>
                  Go to the subscribe page
                </NavigationButton>
              ) : null}
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
