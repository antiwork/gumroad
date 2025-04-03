import * as React from "react";

import { assert } from "$app/utils/assert";

export type UserAgentInfo = { isMobile: boolean; locale: string };

const Context = React.createContext<UserAgentInfo | null>(null);

export const UserAgentProvider = Context.Provider;

export const useUserAgentInfo = (): UserAgentInfo => {
  const value = React.useContext(Context);
  assert(value != null, "Cannot read user-agent context, make sure UserAgentProvider is used");
  return value;
};
