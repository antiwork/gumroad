import * as React from "react";

import { NavigationButton } from "$app/components/Button";

type Props = Omit<React.ComponentProps<typeof NavigationButton>, "color"> & {
  href: string;
  children?: React.ReactNode;
};

export const CommunityButton: React.FC<Props> = ({ href, children = "Community", ...rest }) => (
  <NavigationButton {...rest} href={href} color="warning">
    {children}
  </NavigationButton>
);
