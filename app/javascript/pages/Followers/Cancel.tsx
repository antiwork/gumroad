import * as React from "react";

import { PoweredByFooter } from "$app/components/PoweredByFooter";
import { Card, CardContent } from "$app/components/ui/Card";

function FollowersCancelPage() {
  return (
    <div className="flex min-h-screen flex-col justify-between">
      <Card asChild>
        <main className="mx-auto my-4 h-min max-w-md w-[calc(100%-2rem)]">
          <CardContent asChild>
            <header className="flex-col items-stretch text-center">
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
