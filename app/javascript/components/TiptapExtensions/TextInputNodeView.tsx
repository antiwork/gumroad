import { NodeViewProps, NodeViewWrapper } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { TextInput } from "$app/components/Download/CustomField/TextInput";
import { NodeActionsMenu, NodeActionsWrapper } from "$app/components/TiptapExtensions/NodeActionsMenu";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Textarea } from "$app/components/ui/Textarea";

export const TextInputNodeView = ({ editor, node, updateAttributes }: NodeViewProps) => {
  const label = cast<string | null>(node.attrs.label);
  const type = cast<"shortAnswer" | "longAnswer">(node.type.name);
  const customFieldId = cast<string | null>(node.attrs.id);

  const sharedProps: React.InputHTMLAttributes<HTMLInputElement | HTMLTextAreaElement> = {
    readOnly: true,
    "aria-label": label ?? undefined,
  };

  return (
    <NodeViewWrapper data-drag-handle data-input-embed>
      {editor.isEditable ? (
        <NodeActionsWrapper asChild>
          <Fieldset>
            <NodeActionsMenu editor={editor} />

            <fieldset className="m-0 min-w-0 flex-1 border-0 p-0">
              <Input
                value={label ?? ""}
                placeholder="Title"
                onChange={(evt) => updateAttributes({ label: evt.target.value })}
                className="border-0"
                style={{
                  background: "none",
                  padding: 0,
                  margin: 0,
                  font: "inherit",
                  color: "inherit",
                  outline: "none",
                  border: "none",
                  borderRadius: 0,
                }}
              />
              {type === "shortAnswer" ? <Input {...sharedProps} /> : <Textarea {...sharedProps} />}
            </fieldset>
          </Fieldset>
        </NodeActionsWrapper>
      ) : (
        <Fieldset>
          <TextInput customFieldId={customFieldId ?? ""} type={type} label={label ?? ""} />
        </Fieldset>
      )}
    </NodeViewWrapper>
  );
};
