import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import type { Props as ProductProps } from "$app/components/Product";
import {
  Action,
  AddSectionButton,
  PageProps as EditSectionsProps,
  EditSection,
  Section as EditableSection,
  ReducerContext as SectionReducerContext,
  useSectionImageUploadSettings,
} from "$app/components/Profile/EditSections";
import { SectionLayout } from "$app/components/Profile/Sections";
import { ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { useRefToLatest } from "$app/components/useRefToLatest";

export const SectionEditor = ({
  props,
  controls = true,
  children,
}: {
  props: ProductProps & { main_section_index: number } & EditSectionsProps;
  controls?: boolean;
  children: React.ReactNode;
}) => {
  const { product } = props;
  const [sections, setSections] = React.useState(() => {
    const sections = [...props.sections];
    // fake section (never rendered) to make things easier
    sections.splice(props.main_section_index, 0, {
      type: "SellerProfileFeaturedProductSection",
      id: "",
      featured_product_id: product.id,
      header: "",
      hide_header: true,
    });
    return sections;
  });

  const saveSections = async (sections: EditableSection[]) => {
    setSections(sections);
    const order = sections.map((section) => section.id);
    const mainIndex = order.findIndex((id) => !id);
    order.splice(mainIndex, 1);
    try {
      const response = await request({
        method: "PUT",
        url: Routes.sections_link_path(product.permalink),
        accept: "json",
        data: { sections: order, main_section_index: mainIndex },
      });
      if (!response.ok) throw new ResponseError();
      showAlert("Changes saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const sectionsRef = useRefToLatest(sections);
  const dispatch = (action: Action) => {
    const sections = sectionsRef.current;
    switch (action.type) {
      case "add-section": {
        action.section.then((section) => {
          const newSections = [...sections];
          newSections.splice(action.index, 0, section);
          void saveSections(newSections);
        }, assertResponseError);
        break;
      }
      case "update-section": {
        setSections(sections.map((section) => (section.id === action.updated.id ? action.updated : section)));
        break;
      }
      case "remove-section": {
        void saveSections(sections.filter((section) => section.id !== action.id));
        break;
      }
      case "move-section-up":
      case "move-section-down": {
        const index = sections.findIndex((section) => section.id === action.id);
        const updatedSections = [...sections];
        const [section] = updatedSections.splice(index, 1);
        updatedSections.splice(index + (action.type === "move-section-up" ? -1 : 1), 0, assertDefined(section));
        void saveSections(updatedSections);
      }
    }
  };
  const reducer = React.useMemo(() => [{ ...props, sections, product_id: product.id }, dispatch] as const, [sections]);
  const imageUploadSettings = useSectionImageUploadSettings();

  return (
    <SectionReducerContext.Provider value={reducer}>
      <ImageUploadSettingsContext.Provider value={imageUploadSettings}>
        {sections.map((section, i) => (
          <SectionLayout key={section.id} id={section.id}>
            {controls ? <AddSectionButton index={i} /> : null}
            {section.id ? (
              <EditSection section={section} controls={controls} />
            ) : (
              <div className="mx-auto w-full max-w-6xl">{children}</div>
            )}
            {controls && i === sections.length - 1 ? <AddSectionButton index={i + 1} side="top" /> : null}
          </SectionLayout>
        ))}
      </ImageUploadSettingsContext.Provider>
    </SectionReducerContext.Provider>
  );
};
