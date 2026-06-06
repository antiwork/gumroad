import { isEqual } from "lodash-es";
import * as React from "react";

import { Tab } from "$app/parsers/profile";
import GuidGenerator from "$app/utils/guid_generator";

import AutoLink from "$app/components/AutoLink";
import { FollowUserFormBlock } from "$app/components/Profile/FollowUserForm";
import { Layout } from "$app/components/Profile/Layout";
import { PageProps as SectionsProps, Section, SectionLayout } from "$app/components/Profile/Sections";
import { Tabs as UITabs, Tab as UITab } from "$app/components/ui/Tabs";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRefToLatest } from "$app/components/useRefToLatest";

export type ProfileProps = {
  tabs: Tab[];
  bio: string | null;
};

export type Props = SectionsProps & ProfileProps;

export type TabWithId = Tab & { id: string };

const tabWithoutId = ({ id: _id, ...tab }: TabWithId): Tab => tab;

const sharedSectionCount = (tab: Tab, currentTab: TabWithId) => {
  const currentSectionIds = new Set(currentTab.sections);
  return tab.sections.filter((sectionId) => currentSectionIds.has(sectionId)).length;
};

const tabWithStableIds = (initial: Tab[], currentTabs: TabWithId[] = []) => {
  const usedTabIds = new Set<string>();
  const unusedTabs = () => currentTabs.filter((tab) => !usedTabIds.has(tab.id));

  return initial.map((tab) => {
    const exactMatch = unusedTabs().find((currentTab) => isEqual(tabWithoutId(currentTab), tab));
    const sectionMatch =
      exactMatch ??
      (tab.sections.length
        ? unusedTabs()
            .map((currentTab) => ({ tab: currentTab, sharedSections: sharedSectionCount(tab, currentTab) }))
            .filter(({ sharedSections }) => sharedSections > 0)
            .sort((a, b) => b.sharedSections - a.sharedSections)[0]?.tab
        : unusedTabs().find((currentTab) => currentTab.sections.length === 0 && currentTab.name === tab.name));
    const id = sectionMatch?.id ?? GuidGenerator.generate();
    usedTabIds.add(id);
    return { ...tab, id };
  });
};

export function useTabs(initial: Tab[]) {
  const [tabs, setTabs] = React.useState(() => tabWithStableIds(initial));

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
    setTabs((currentTabs) => {
      if (
        isEqual(
          currentTabs.map(({ id: _id, ...tab }) => tab),
          initial,
        )
      )
        return currentTabs;

      return tabWithStableIds(initial, currentTabs);
    });
  }, [initial]);

  React.useEffect(() => {
    if (selectedTabId && tabs.some((tab) => tab.id === selectedTabId)) return;
    setSelectedTabId(tabs[0]?.id);
  }, [selectedTabId, tabs]);

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
        <header className="border-b border-border">
          <div className="mx-auto grid w-full max-w-6xl grid-cols-1 gap-4 px-4 py-8 lg:px-0">
            {props.bio ? (
              <h1 className="whitespace-pre-line">
                <AutoLink text={props.bio} />
              </h1>
            ) : null}
            {props.tabs.length > 1 ? (
              <UITabs aria-label="Profile Tabs">
                {tabs.map((tab) => (
                  <UITab key={tab.id} isSelected={tab === selectedTab} onClick={() => setSelectedTab(tab)}>
                    {tab.name}
                  </UITab>
                ))}
              </UITabs>
            ) : null}
          </div>
        </header>
      ) : null}
      {sections?.length ? (
        sections.map((section) => <Section key={section.id} section={section} {...props} />)
      ) : (
        <SectionLayout className="grid flex-1">
          <FollowUserFormBlock creatorProfile={props.creator_profile} />
        </SectionLayout>
      )}
    </>
  );
};

export const Profile = (props: Props) => (
  <Layout creatorProfile={props.creator_profile} hideFollowForm={!props.sections.length}>
    <PublicProfile {...props} />
  </Layout>
);
