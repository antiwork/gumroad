import { Trash } from "@boxicons/react";
import CharacterCount from "@tiptap/extension-character-count";
import { EditorContent, useEditor } from "@tiptap/react";
import { isEqual } from "lodash-es";
import * as React from "react";
import { ReactSortable as Sortable } from "react-sortablejs";

import { updateProfileSettings } from "$app/data/profile_settings";
import GuidGenerator from "$app/utils/guid_generator";
import { assertResponseError } from "$app/utils/request";

import AutoLink from "$app/components/AutoLink";
import { Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { ProfileProps, TabWithId, useTabs } from "$app/components/Profile";
import { SectionLayout } from "$app/components/Profile/Sections";
import { ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import PlainTextStarterKit from "$app/components/TiptapExtensions/PlainTextStarterKit";
import { Row, RowActions, RowContent, RowDragHandle, Rows } from "$app/components/ui/Rows";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { useRefToLatest } from "$app/components/useRefToLatest";

import {
  Action,
  AddSectionButton,
  EditorMenu,
  EditorSubmenu,
  EditSection,
  ReducerContext as SectionReducerContext,
  PageProps as SectionsProps,
  SectionToolbar,
  useSectionImageUploadSettings,
} from "./EditSections";
import { FollowFormBlock } from "./FollowForm";

export type ProfileEditorProps = ProfileProps & SectionsProps;
export type ProfileEditorState = Pick<ProfileEditorProps, "sections" | "tabs">;
export type Props = ProfileEditorProps & {
  controls?: boolean;
  onChange?: (state: ProfileEditorState) => void;
};

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
    <Row role="listitem">
      <RowContent>
        <RowDragHandle aria-grabbed={dragging} />
        <h4 style={{ flex: 1 }}>
          <EditorContent editor={editor} />
        </h4>
      </RowContent>
      <RowActions>
        <Button size="icon" color="danger" outline aria-label="Remove page" onClick={() => setConfirmingDelete(true)}>
          <Trash className="size-5" />
        </Button>
      </RowActions>
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
    </Row>
  );
};

// TODO: Use a better library than react-sortablejs that can solve this more cleanly
const TabList = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>(({ children }, ref) => (
  <Rows role="list" ref={ref} aria-label="Pages">
    {children}
  </Rows>
));
TabList.displayName = "TabList";

const tabsWithoutIds = (tabs: TabWithId[]) => tabs.map(({ id: _id, ...tab }) => tab);

export const EditProfile = ({ controls = true, onChange, ...props }: Props) => {
  const [sections, setSections] = React.useState(props.sections);
  const { tabs, setTabs, selectedTab, setSelectedTab } = useTabs(props.tabs);
  const updateTab = (tab: TabWithId) => setTabs(tabs.map((existing) => (existing.id === tab.id ? tab : existing)));
  const [hasAddedTab, setHasAddedTab] = React.useState(false);

  React.useEffect(() => {
    setSections((currentSections) => (isEqual(currentSections, props.sections) ? currentSections : props.sections));
  }, [props.sections]);

  React.useEffect(() => onChange?.({ sections, tabs: tabsWithoutIds(tabs) }), [onChange, sections, tabs]);

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
  const reducer = React.useMemo(
    () => [{ ...props, sections: visibleSections }, dispatch] as const,
    [props, visibleSections],
  );

  const imageUploadSettings = useSectionImageUploadSettings();

  return (
    <SectionReducerContext.Provider value={reducer}>
      {controls || props.bio || tabs.length > 1 ? (
        <header className="relative grid gap-4 border-b border-border px-4 py-8">
          {controls ? (
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
          ) : null}
          <div className="mx-auto grid w-full max-w-6xl gap-4">
            {props.bio ? (
              <h1 className="whitespace-pre-line">
                <AutoLink text={props.bio} />
              </h1>
            ) : null}
            {controls || tabs.length > 1 ? (
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
            ) : null}
          </div>
        </header>
      ) : null}
      {visibleSections.length ? (
        visibleSections.map((section, i) => (
          <SectionLayout
            key={section.id}
            id={section.id}
            style={{ overflowAnchor: section.id === movedSectionId ? "none" : undefined }}
          >
            {controls ? <AddSectionButton index={i} /> : null}
            <ImageUploadSettingsContext.Provider value={imageUploadSettings}>
              <EditSection section={section} controls={controls} />
            </ImageUploadSettingsContext.Provider>
            {controls && i === visibleSections.length - 1 ? <AddSectionButton index={i + 1} side="top" /> : null}
          </SectionLayout>
        ))
      ) : (
        <SectionLayout className="grid flex-1">
          {controls ? <AddSectionButton index={0} /> : null}
          <FollowFormBlock creatorProfile={props.creator_profile} />
          {controls ? <AddSectionButton index={0} side="top" /> : null}
        </SectionLayout>
      )}
    </SectionReducerContext.Provider>
  );
};
