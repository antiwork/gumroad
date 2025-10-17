import CharacterCount from "@tiptap/extension-character-count";
import { EditorContent, useEditor } from "@tiptap/react";
import isEqual from "lodash/isEqual";
import * as React from "react";
import { ReactSortable as Sortable } from "react-sortablejs";

import { updateProfileSettings } from "$app/data/profile_settings";
import GuidGenerator from "$app/utils/guid_generator";
import { assertResponseError } from "$app/utils/request";

import AutoLink from "$app/components/AutoLink";
import { Button, NavigationButton } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";
import { SectionLayout } from "$app/components/Profile/Sections";
import { ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { ProfileProps, TabWithId, useTabs } from "$app/components/server-components/Profile";
import PlainTextStarterKit from "$app/components/TiptapExtensions/PlainTextStarterKit";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip } from "$app/components/WithTooltip";

import {
  AddSectionButton,
  EditorMenu,
  EditorSubmenu,
  PageProps as SectionsProps,
  ReducerContext as SectionReducerContext,
  Action,
  EditSection,
  useSectionImageUploadSettings,
  SectionToolbar,
} from "./EditSections";
import { FollowFormBlock } from "./FollowForm";

export type Props = ProfileProps & SectionsProps;

const EditTab = ({
  tab,
  dragging,
  focus,
  update,
  remove,
}: {
  tab: TabWithId;
  dragging: boolean;
  focus: boolean;
  update: (tab: TabWithId) => void;
  remove: () => void;
}) => {
  const draggingRef = useRefToLatest(dragging);
  const [confirmingDelete, setConfirmingDelete] = React.useState(false);
  const editor = useEditor({
    extensions: [PlainTextStarterKit, CharacterCount.configure({ limit: 40 })],
    content: tab.name,
    onUpdate: ({ editor }) => update({ ...tab, name: editor.getText() }),
    editorProps: {
      handleDrop: () => draggingRef.current, // prevent reordering items also pasting their text
      attributes: { "aria-label": "Page name" },
    },
  });
  React.useEffect(() => {
    if (focus) editor?.commands.focus("end");
  }, [editor]);
  return (
    <div role="listitem" className="row">
      <div className="content">
        <div aria-grabbed={dragging} />
        <h4 style={{ flex: 1 }}>
          <EditorContent editor={editor} />
        </h4>
      </div>
      <div className="actions">
        <Button small color="danger" outline aria-label="Remove page" onClick={() => setConfirmingDelete(true)}>
          <Icon name="trash2" />
        </Button>
      </div>
      {confirmingDelete ? (
        <Modal
          open
          onClose={() => setConfirmingDelete(false)}
          title="Delete page?"
          footer={
            <>
              <Button onClick={() => setConfirmingDelete(false)}>No, cancel</Button>
              <Button color="danger" onClick={remove}>
                Yes, delete
              </Button>
            </>
          }
        >
          Are you sure you want to delete the page "{tab.name}"? <strong>This action cannot be undone.</strong>
        </Modal>
      ) : null}
    </div>
  );
};

// TODO: Use a better library than react-sortablejs that can solve this more cleanly
const TabList = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <div className="rows" role="list" ref={ref} aria-label="Pages">
    {children}
  </div>
));
TabList.displayName = "TabList";

export const EditProfile = (props: Props) => {
  const appDomain = useAppDomain();

  const [sections, setSections] = React.useState(props.sections);
  const { tabs, setTabs, selectedTab, setSelectedTab } = useTabs(props.tabs);
  const updateTab = (tab: TabWithId) => setTabs(tabs.map((existing) => (existing.id === tab.id ? tab : existing)));
  const [hasAddedTab, setHasAddedTab] = React.useState(false);

  const addTab = () => {
    const tab = { id: GuidGenerator.generate(), name: "New page", sections: [] };
    setTabs([...tabs, tab]);
    setHasAddedTab(true);
    if (tabs.length === 0) setSelectedTab(tab);
    return tab;
  };

  const savedTabs = React.useRef(tabs);
  const saveTabs = async (tabs: TabWithId[]) => {
    setTabs(tabs);
    if (isEqual(tabs, savedTabs.current)) return;
    try {
      await updateProfileSettings({ tabs });
      showAlert("Changes saved!", "success");
      savedTabs.current = tabs;
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const [newSectionId, setNewSectionId] = React.useState<string | null>(null);
  React.useEffect(() => {
    if (newSectionId) window.location.hash = newSectionId;
  }, [newSectionId]);
  const [movedSectionId, setMovedSectionId] = React.useState<string | null>(null);
  React.useEffect(() => setMovedSectionId(null), [movedSectionId]);

  const tabsRef = useRefToLatest(tabs);
  const dispatch = (action: Action) => {
    switch (action.type) {
      case "add-section": {
        const currentTab = selectedTab ?? addTab();
        action.section.then((section) => {
          setSections((sections) => [...sections, section]);
          void saveTabs(
            tabsRef.current.map((tab) => {
              if (tab.id !== currentTab.id) return tab;
              const sections = [...tab.sections];
              sections.splice(action.index, 0, section.id);
              return { ...tab, sections };
            }),
          );
          setNewSectionId(section.id);
        }, assertResponseError);
        break;
      }
      case "update-section": {
        setSections(sections.map((section) => (section.id === action.updated.id ? action.updated : section)));
        break;
      }
      case "remove-section": {
        setSections(sections.filter((section) => section.id !== action.id));
        void saveTabs(tabs.map((tab) => ({ ...tab, sections: tab.sections.filter((id) => id !== action.id) })));
        break;
      }
      case "move-section-up":
      case "move-section-down": {
        const tab = tabs.find((tab) => tab.sections.includes(action.id));
        if (!tab) return;
        const sections = [...tab.sections];
        const index = sections.findIndex((id) => id === action.id);
        if (action.type === "move-section-up" ? index === 0 : index >= sections.length - 1) return;
        setMovedSectionId(action.id);
        sections.splice(index, 1);
        sections.splice(index + (action.type === "move-section-up" ? -1 : 1), 0, action.id);
        void saveTabs(tabs.map((existing) => (existing === tab ? { ...tab, sections } : existing)));
      }
    }
  };
  const [draggedTab, setDraggedTab] = React.useState<string | null>();
  const visibleSections =
    selectedTab?.sections.flatMap((id) => sections.find((section) => section.id === id) ?? []) ?? [];
  const reducer = React.useMemo(() => [{ ...props, sections: visibleSections }, dispatch] as const, [visibleSections]);

  const imageUploadSettings = useSectionImageUploadSettings();
  const isDesktop = useIsAboveBreakpoint("lg");

  return (
    <SectionReducerContext.Provider value={reducer}>
      <header className="relative grid grid-cols-1 gap-4 border-b border-border px-4 py-8">
        {/* Work around position:absolute being affected by header's grid */}
        <SectionToolbar>
          <EditorMenu label="Page settings" onClose={() => void saveTabs(tabs)}>
            <EditorSubmenu heading="Pages" text={tabs.length}>
              {tabs.length > 0 ? (
                <Sortable
                  list={tabs}
                  setList={setTabs}
                  tag={TabList}
                  handle="[aria-grabbed]"
                  onChoose={(e) => setDraggedTab(tabs[e.oldIndex ?? -1]?.id ?? null)}
                  onUnchoose={() => setDraggedTab(null)}
                >
                  {tabs.map((tab) => (
                    <EditTab
                      key={tab.id}
                      tab={tab}
                      dragging={tab.id === draggedTab}
                      focus={hasAddedTab}
                      update={updateTab}
                      remove={() => setTabs(tabs.filter((existing) => existing !== tab))}
                    />
                  ))}
                </Sortable>
              ) : null}
              <Button onClick={addTab}>New page</Button>
            </EditorSubmenu>
          </EditorMenu>
        </SectionToolbar>
        {props.bio ? (
          <h1 style={{ whiteSpace: "pre-line" }}>
            <AutoLink text={props.bio} />
          </h1>
        ) : null}
        <Tabs aria-label="Profile Tabs">
          {tabs.map((tab) => (
            <Tab
              key={tab.id}
              isSelected={tab === selectedTab}
              onClick={() => {
                if (imageUploadSettings.isUploading) {
                  showAlert("Please wait for all images to finish uploading before switching tabs.", "warning");
                  return;
                }
                setSelectedTab(tab);
              }}
            >
              {tab.name}
            </Tab>
          ))}
        </Tabs>
      </header>
      <div className="fixed! top-5 right-3 z-30 p-0! lg:top-3 lg:right-auto lg:left-3">
        <WithTooltip tip="Edit profile" position={isDesktop ? "right" : "left"}>
          <NavigationButton
            color="filled"
            href={Routes.settings_profile_url({ host: appDomain })}
            aria-label="Edit profile"
          >
            <Icon name="pencil" />
          </NavigationButton>
        </WithTooltip>
      </div>
      {visibleSections.length ? (
        visibleSections.map((section, i) => (
          <SectionLayout
            key={section.id}
            id={section.id}
            style={{ overflowAnchor: section.id === movedSectionId ? "none" : undefined }}
          >
            <AddSectionButton index={i} />
            <ImageUploadSettingsContext.Provider value={imageUploadSettings}>
              <EditSection section={section} />
            </ImageUploadSettingsContext.Provider>
            {i === visibleSections.length - 1 ? <AddSectionButton index={i + 1} position="top" /> : null}
          </SectionLayout>
        ))
      ) : (
        <SectionLayout className="grid flex-1">
          <AddSectionButton index={0} />
          <FollowFormBlock creatorProfile={props.creator_profile} />
          <AddSectionButton index={0} position="top" />
        </SectionLayout>
      )}
    </SectionReducerContext.Provider>
  );
};
