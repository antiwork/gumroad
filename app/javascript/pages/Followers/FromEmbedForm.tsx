import { usePage } from "@inertiajs/react";
import * as React from "react";

import { cast } from "$app/utils/cast";

import { NavigationButton } from "$app/components/Button";
import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";

type Props = {
  success: boolean;
  message: string;
  // True on the success path when the follow is already confirmed. A follow that
  // still needs an inbox confirmation must not be headed as if it were done.
  confirmed?: boolean;
  // Present when the subscribe couldn't be accepted from the embed form and the
  // visitor has to finish it on the seller's own Gumroad page, which renders a
  // CAPTCHA. Absent on every other outcome.
  subscribe_url?: string | null;
};

function FollowersFromEmbedFormPage() {
  const { success, message, confirmed, subscribe_url } = cast<Props>(usePage().props);

  return (
    <div className="flex flex-1 flex-col justify-between p-4">
      <Card asChild>
        <main className="mx-auto h-min w-full max-w-md">
          <CardContent asChild>
            <header className="text-center">
              <h2>{success ? (confirmed ? "Followed!" : "Almost there") : "Something went wrong"}</h2>
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
