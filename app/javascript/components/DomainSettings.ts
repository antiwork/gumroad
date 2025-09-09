import * as React from "react";

import { assert } from "$app/utils/assert";

type DomainSettings = {
  scheme: string;
  appDomain: string;
  rootDomain: string;
  shortDomain: string;
  discoverDomain: string;
  thirdPartyAnalyticsDomain: string;
  apiDomain: string;
};

const Context = React.createContext<DomainSettings | null>(null);

export const useAppDomain = (): string => {
  const value = React.useContext(Context);
  assert(value != null, "Cannot read domain settings, make sure DomainSettingsProvider is used");
  return value.appDomain;
};

export const useDomains = (): DomainSettings => {
  const value = React.useContext(Context);
  assert(value != null, "Cannot read domain settings, make sure DomainSettingsProvider is used");
  return value;
};

export const useDiscoverUrl = (): string => {
  const value = React.useContext(Context);
  assert(value != null, "Cannot read domain settings, make sure DomainSettingsProvider is used");
  return Routes.discover_url({ protocol: value.scheme, host: value.discoverDomain });
};

export const DomainSettingsProvider = Context.Provider;
