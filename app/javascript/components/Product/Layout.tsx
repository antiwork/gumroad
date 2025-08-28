import * as React from "react";

import { assertDefined } from "$app/utils/assert";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { NavigationButton } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Product, useSelectionFromUrl, Props as ProductProps } from "$app/components/Product";
import { ConfigurationSelectorHandle } from "$app/components/Product/ConfigurationSelector";
import {
  Action,
  AddSectionButton,
  PageProps as EditSectionsProps,
  EditSection,
  Section as EditableSection,
  ReducerContext as SectionReducerContext,
  useSectionImageUploadSettings,
} from "$app/components/Profile/EditSections";
import { Section, PageProps as SectionsProps } from "$app/components/Profile/Sections";
import { ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";

import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip } from "$app/components/WithTooltip";

export type Props = ProductProps & { main_section_index: number } & (SectionsProps | EditSectionsProps);

const SectionEditor = ({
  props,
  children,
}: {
  props: Extract<Props, EditSectionsProps>;
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
          <section key={section.id} id={section.id}>
            <AddSectionButton index={i} />
            {section.id ? <EditSection section={section} /> : children}
            {i === sections.length - 1 ? <AddSectionButton index={i + 1} position="top" /> : null}
          </section>
        ))}
      </ImageUploadSettingsContext.Provider>
    </SectionReducerContext.Provider>
  );
};

export const Layout = (
  props: Props & {
    cart?: boolean;
    hasHero?: boolean;
  },
) => {
  const { product, purchase, discount_code: discountCode, cart, wishlists, main_section_index } = props;
  const [selection, setSelection] = useSelectionFromUrl(product);
  const ctaButtonRef = React.useRef<HTMLAnchorElement>(null);
  const ctaLabel = cart ? "Add to cart" : undefined;

  const configurationSelectorRef = React.useRef<ConfigurationSelectorHandle>(null);

  const productView = (
    <>
      <EditButton product={product} />
      <Product
        product={product}
        purchase={purchase}
        discountCode={discountCode ?? null}
        ctaLabel={ctaLabel}
        selection={selection}
        setSelection={setSelection}
        ctaButtonRef={ctaButtonRef}
        configurationSelectorRef={configurationSelectorRef}
        wishlists={wishlists}
      />
    </>
  );

  const mainSection = <section>{productView}</section>;

  return (
    <>
      {"products" in props ? (
        <SectionEditor props={props}>{productView}</SectionEditor>
      ) : props.sections.length > 0 ? (
        props.sections.map((section, i) => (
          <React.Fragment key={section.id}>
            {i === main_section_index ? mainSection : null}
            <Section section={section} {...props} />
            {main_section_index >= props.sections.length && i === props.sections.length - 1 ? mainSection : null}
          </React.Fragment>
        ))
      ) : (
        mainSection
      )}
    </>
  );
};

const EditButton = ({ product }: { product: Product }) => {
  const appDomain = useAppDomain();

  if (!product.can_edit) return null;

  return (
    <div
      style={{
        position: "absolute",
        top: "var(--spacer-3)",
        left: "var(--spacer-3)",
        // Render above the product `article`
        zIndex: "var(--z-index-overlay)",
      }}
    >
      <WithTooltip tip="Edit product" position="right">
        <NavigationButton
          color="filled"
          href={Routes.edit_link_url({ id: product.permalink }, { host: appDomain })}
          aria-label="Edit product"
        >
          <Icon name="pencil" />
        </NavigationButton>
      </WithTooltip>
    </div>
  );
};
