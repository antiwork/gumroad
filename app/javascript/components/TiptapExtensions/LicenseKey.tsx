import { Node as TiptapNode } from "@tiptap/core";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { Drawer } from "$app/components/SortableList";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";
import { Toggle } from "$app/components/Toggle";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    licenseKey: {
      insertLicenseKey: (options: Record<string, never>) => ReturnType;
    };
  }
}

export const LicenseKey = TiptapNode.create({
  name: "licenseKey",
  selectable: true,
  draggable: true,
  atom: true,
  group: "block",
  parseHTML: () => [{ tag: "license-key" }],
  renderHTML: ({ HTMLAttributes }) => ["license-key", HTMLAttributes],
  addNodeView() {
    return ReactNodeViewRenderer(LicenseKeyNodeView);
  },
  addCommands() {
    return {
      insertLicenseKey: createInsertCommand("licenseKey"),
    };
  },
});

const LicenseKeyNodeView = ({ editor, selected }: NodeViewProps) => {
  const [isDrawerOpen, setIsDrawerOpen] = React.useState(false);
  const { licenseKey, isMultiSeatLicense, seats, onIsMultiSeatLicenseChange, productId } = useLicense();
  const uid = React.useId();

  return (
    <NodeViewWrapper>
      <div className={cx("embed", { selected })}>
        {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
        <div className="content" contentEditable={false}>
          <Icon name="solid-key" className="type-icon" />
          <div>
            <h4 className="text-singleline">{licenseKey}</h4>
            <ul className="inline">
              <li>{editor.isEditable ? "License key (sample)" : "License key"}</li>
              {isMultiSeatLicense && seats !== null ? <li>{`${seats} ${seats === 1 ? "Seat" : "Seats"}`}</li> : null}
            </ul>
          </div>
        </div>

        <div className="actions">
          {licenseKey !== null ? (
            <CopyToClipboard text={licenseKey}>
              <Button>Copy</Button>
            </CopyToClipboard>
          ) : null}
          {editor.isEditable ? (
            <Button onClick={() => setIsDrawerOpen(!isDrawerOpen)} aria-label={isDrawerOpen ? "Close drawer" : "Edit"}>
              <Icon name={isDrawerOpen ? "outline-cheveron-up" : "outline-cheveron-down"} />
            </Button>
          ) : null}
        </div>
        {editor.isEditable && isDrawerOpen ? (
          <Drawer>
            {isMultiSeatLicense !== null ? (
              <Toggle value={isMultiSeatLicense} onChange={assertDefined(onIsMultiSeatLicenseChange)}>
                Allow customers to choose number of seats per license purchased
              </Toggle>
            ) : null}
            {productId ? (
              <fieldset>
                <legend>
                  <label htmlFor={`product_id-${uid}`}>Use your product ID to verify licenses through the API.</label>
                </legend>
                <div className="flex gap-2">
                  <input id={`product_id-${uid}`} type="text" value={productId} className="flex-1" readOnly />
                  <CopyToClipboard text={productId} tooltipPosition="bottom">
                    <a className="button">Copy</a>
                  </CopyToClipboard>
                </div>
              </fieldset>
            ) : null}
          </Drawer>
        ) : null}
      </div>
    </NodeViewWrapper>
  );
};

const LicenseContext = React.createContext<{
  licenseKey: string | null;
  isMultiSeatLicense: boolean | null;
  seats: number | null;
  onIsMultiSeatLicenseChange?: (newValue: boolean) => void;
  productId?: string;
} | null>(null);
export const LicenseProvider = LicenseContext.Provider;
const useLicense = () =>
  assertDefined(React.useContext(LicenseContext), "useLicense must be used within a LicenseProvider");
