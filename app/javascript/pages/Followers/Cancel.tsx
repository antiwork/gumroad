import * as React from "react";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";

function FollowersCancelPage() {
  return (
    <div className="flex flex-1 flex-col justify-between p-4">
      <Card asChild>
        <main className="mx-auto h-min w-full max-w-md">
          <CardContent asChild>
            <header className="text-center">
              <h2>You have been unsubscribed.</h2>
              <p>You will no longer get posts from this creator.</p>
            </header>
          </CardContent>
        </main>
      </Card>
      <PoweredByFooter />
    </div>
  );
}

FollowersCancelPage.loggedInUserLayout = true;
export default FollowersCancelPage;
