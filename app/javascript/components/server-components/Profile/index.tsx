import * as React from "react";
import { createCast } from "ts-safe-cast";

import { Tab } from "$app/parsers/profile";
import GuidGenerator from "$app/utils/guid_generator";
import { register } from "$app/utils/serverComponentUtil";

import AutoLink from "$app/components/AutoLink";
import { EditProfile, Props as EditProps } from "$app/components/Profile/EditPage";
import { FollowFormBlock } from "$app/components/Profile/FollowForm";
import { Layout } from "$app/components/Profile/Layout";
import { PageProps as SectionsProps, Section } from "$app/components/Profile/Sections";
import { Tabs as UITabs, Tab as UITab } from "$app/components/ui/Tabs";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRefToLatest } from "$app/components/useRefToLatest";

export type ProfileProps = {
  tabs: Tab[];
  bio: string | null;
};

export type Props = SectionsProps & ProfileProps;

export type TabWithId = Tab & { id: string };
export function useTabs(initial: Tab[]) {
  const [tabs, setTabs] = React.useState(() => initial.map((tab) => ({ ...tab, id: GuidGenerator.generate() })));

  const location = new URL(useOriginalLocation());
  const urlSection = React.useRef(location.searchParams.get("section"));
  const [selectedTabId, setSelectedTabId] = React.useState(
    (tabs.find((tab) => tab.sections.includes(urlSection.current ?? "")) ?? tabs[0])?.id,
  );
  const setSelectedTab = (tab: TabWithId) => {
    setSelectedTabId(tab.id);
    const section = tab.sections[0];
    const location = new URL(window.location.href);
    if (!section || section === location.searchParams.get("section")) return;
    location.searchParams.set("section", section);
    window.history.pushState(null, "", location.toString());
  };

  const tabsRef = useRefToLatest(tabs);
  React.useEffect(() => {
    const listener = () => {
      const tabs = tabsRef.current;
      const section = new URL(window.location.href).searchParams.get("section");
      if (section === urlSection.current) return;
      urlSection.current = section;
      const tab = section ? tabs.find((tab) => tab.sections.includes(urlSection.current ?? "")) : tabs[0];
      if (tab) setSelectedTabId(tab.id);
    };
    window.addEventListener("popstate", listener);
    return () => window.removeEventListener("popstate", listener);
  }, []);

  return { tabs, setTabs, selectedTab: tabs.find((tab) => tab.id === selectedTabId) ?? tabs[0], setSelectedTab };
}

const PublicProfile = (props: Props) => {
  const { tabs, selectedTab, setSelectedTab } = useTabs(props.tabs);
  const sections = selectedTab?.sections.flatMap((id) => props.sections.find((section) => section.id === id) ?? []);

  return (
    <>
      {props.bio || props.tabs.length > 1 ? (
        <header className="grid grid-cols-1 gap-4 border-b border-border px-4 py-8">
          {props.bio ? (
            <h1 style={{ whiteSpace: "pre-line" }}>
              <AutoLink text={props.bio} />
            </h1>
          ) : null}
          {props.tabs.length > 1 ? (
            <UITabs aria-label="Profile Tabs">
              {tabs.map((tab, i) => (
                <UITab key={i} isSelected={tab === selectedTab} onClick={() => setSelectedTab(tab)}>
                  {tab.name}
                </UITab>
              ))}
            </UITabs>
          ) : null}
        </header>
      ) : null}
      {sections?.length ? (
        sections.map((section) => <Section key={section.id} section={section} {...props} />)
      ) : (
        <FollowFormBlock creatorProfile={props.creator_profile} />
      )}
    </>
  );
};

export const Profile = (props: Props | EditProps) => (
  <Layout creatorProfile={props.creator_profile} hideFollowForm={!props.sections.length}>
    {"products" in props ? <EditProfile {...props} /> : <PublicProfile {...props} />}
  </Layout>
);

export default register({ component: Profile, propParser: createCast() });
