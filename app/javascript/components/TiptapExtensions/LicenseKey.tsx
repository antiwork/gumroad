import { ChevronDown, ChevronUp, Key } from "@boxicons/react";
import { Node as TiptapNode } from "@tiptap/core";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import * as React from "react";

import { assertDefined } from "$app/utils/assert";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Drawer } from "$app/components/SortableList";
import { NodeActionsMenu, NodeActionsWrapper } from "$app/components/TiptapExtensions/NodeActionsMenu";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
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
      <NodeActionsWrapper selected={selected} isEditable={editor.isEditable} asChild>
        <Row className="embed">
          {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
          <RowContent className="content" contentEditable={false}>
            <Key pack="filled" className="type-icon size-5" />
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
              <Button
                size="icon"
                onClick={() => setIsDrawerOpen(!isDrawerOpen)}
                aria-label={isDrawerOpen ? "Close drawer" : "Edit"}
              >
                {isDrawerOpen ? <ChevronUp className="size-5" /> : <ChevronDown className="size-5" />}
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
                  <Fieldset>
                    <FieldsetTitle>
                      <Label htmlFor={`product_id-${uid}`}>
                        Use your product ID to verify licenses through the API.
                      </Label>
                    </FieldsetTitle>
                    <div className="flex gap-2">
                      <Input id={`product_id-${uid}`} type="text" value={productId} className="flex-1" readOnly />
                      <CopyToClipboard text={productId} tooltipPosition="bottom">
                        <Button>Copy</Button>
                      </CopyToClipboard>
                    </div>
                  </Fieldset>
                ) : null}
              </Drawer>
            </RowDetails>
          ) : null}
        </Row>
      </NodeActionsWrapper>
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
