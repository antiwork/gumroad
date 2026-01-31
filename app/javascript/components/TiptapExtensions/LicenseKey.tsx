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
import { Row, RowActions, RowContent, RowDetails } from "$app/components/ui/Rows";
import { Switch } from "$app/components/ui/Switch";

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
      <Row className={cx("embed", { selected })}>
        {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
        <RowContent className="content" contentEditable={false}>
          <Icon name="solid-key" className="type-icon" />
          <div>
            <h4 className="text-singleline">{licenseKey}</h4>
            <ul className="inline">
              <li>{editor.isEditable ? "License key (sample)" : "License key"}</li>
              {isMultiSeatLicense && seats !== null ? <li>{`${seats} ${seats === 1 ? "Seat" : "Seats"}`}</li> : null}
            </ul>
          </div>
        </RowContent>

        <RowActions>
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
        </RowActions>
        {editor.isEditable && isDrawerOpen ? (
          <RowDetails asChild>
            <Drawer>
              {isMultiSeatLicense !== null ? (
                <Switch
                  checked={isMultiSeatLicense}
                  onChange={(e) => assertDefined(onIsMultiSeatLicenseChange)(e.target.checked)}
                  label="Allow customers to choose number of seats per license purchased"
                />
              ) : null}
              {productId ? (
                <fieldset>
                  <legend>
                    <label htmlFor={`product_id-${uid}`}>Use your product ID to verify licenses through the API.</label>
                  </legend>
                  <div className="flex gap-2">
                    <input id={`product_id-${uid}`} type="text" value={productId} className="flex-1" readOnly />
                    <CopyToClipboard text={productId} tooltipPosition="bottom">
                      <Button>Copy</Button>
                    </CopyToClipboard>
                  </div>
                </fieldset>
              ) : null}
            </Drawer>
          </RowDetails>
        ) : null}
      </Row>
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
