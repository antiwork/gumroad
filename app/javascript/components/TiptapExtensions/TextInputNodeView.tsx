import { NodeViewProps, NodeViewWrapper } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { TextInput } from "$app/components/Download/CustomField/TextInput";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";

export const TextInputNodeView = ({ editor, node, updateAttributes }: NodeViewProps) => {
  const label = cast<string | null>(node.attrs.label);
  const type = cast<"shortAnswer" | "longAnswer">(node.type.name);
  const customFieldId = cast<string | null>(node.attrs.id);

  const sharedProps: React.InputHTMLAttributes<HTMLInputElement | HTMLTextAreaElement> = {
    readOnly: true,
    "aria-label": label ?? undefined,
  };

  return (
    <NodeViewWrapper data-drag-handle>
      {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
      <fieldset>
        {editor.isEditable ? (
          <>
            <input
              value={label ?? ""}
              placeholder="Title"
              onChange={(evt) => updateAttributes({ label: evt.target.value })}
              className="w-full border-0 bg-transparent p-0 font-inherit text-inherit outline-none"
            />
            {type === "shortAnswer" ? <input {...sharedProps} /> : <textarea {...sharedProps} />}
          </>
        ) : (
          <TextInput customFieldId={customFieldId ?? ""} type={type} label={label ?? ""} />
        )}
      </fieldset>
    </NodeViewWrapper>
  );
};
