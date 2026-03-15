import { StripeConnectInstance } from "@stripe/connect-js";
import { ConnectComponentsProvider, ConnectNotificationBanner } from "@stripe/react-connect-js";
import * as React from "react";

import { getStripeConnectInstance } from "$app/utils/stripe_loader";

import { Skeleton } from "$app/components/Skeleton";
import { useRunOnce } from "$app/components/useRunOnce";

export const StripeConnectEmbeddedNotificationBanner = () => {
  const [connectInstance, setConnectInstance] = React.useState<null | StripeConnectInstance>(null);

  const [isLoading, setIsLoading] = React.useState(true);

  useRunOnce(() => {
    setConnectInstance(getStripeConnectInstance());
  });

  const loader = <Skeleton className="h-40" />;

  return (
    <section>
      {connectInstance ? (
        <ConnectComponentsProvider connectInstance={connectInstance}>
          <ConnectNotificationBanner
            collectionOptions={{
              fields: "eventually_due",
              futureRequirements: "include",
            }}
            onNotificationsChange={() => setIsLoading(false)}
            onLoadError={() => setIsLoading(false)}
          />
          {isLoading ? loader : null}
        </ConnectComponentsProvider>
      ) : (
        loader
      )}
    </section>
  );
};
