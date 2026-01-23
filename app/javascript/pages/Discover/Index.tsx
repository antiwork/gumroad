import React from "react";
import { Head } from "@inertiajs/react";
import { Discover } from "$app/components/server-components/Discover";

type Props = React.ComponentProps<typeof Discover> & { canonical_url?: string; meta_description?: string };

export default function DiscoverPage(props: Props) {
  return (
    <>
      <Head>
        {props.canonical_url && <link rel="canonical" href={props.canonical_url} />}
        {props.meta_description && (
          <>
            <meta name="description" content={props.meta_description} />
            <meta property="og:description" content={props.meta_description} />
          </>
        )}
      </Head>
      <Discover {...props} />
    </>
  );
}

DiscoverPage.disableLayout = true;
