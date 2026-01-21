import CodeBlockLowlight, { CodeBlockLowlightOptions } from "@tiptap/extension-code-block-lowlight";
import { NodeViewContent, NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import { common, createLowlight } from "lowlight";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";

const lowlight = createLowlight(common);

const LANGUAGES = lowlight.listLanguages().map((lang) => {
  const languageMap: Record<string, string> = {
    arduino: "Arduino",
    bash: "Bash",
    c: "C",
    cpp: "C++",
    csharp: "C#",
    css: "CSS",
    diff: "Diff",
    go: "Go",
    graphql: "GraphQL",
    ini: "INI",
    java: "Java",
    javascript: "JavaScript",
    json: "JSON",
    kotlin: "Kotlin",
    less: "Less",
    lua: "Lua",
    makefile: "Makefile",
    markdown: "Markdown",
    objectivec: "Objective-C",
    perl: "Perl",
    php: "PHP",
    "php-template": "PHP Template",
    plaintext: "Plain Text",
    python: "Python",
    "python-repl": "Python REPL",
    r: "R",
    ruby: "Ruby",
    rust: "Rust",
    scss: "SCSS",
    shell: "Shell",
    sql: "SQL",
    swift: "Swift",
    typescript: "TypeScript",
    vbnet: "VB.NET",
    wasm: "WebAssembly",
    xml: "XML",
    yaml: "YAML",
  };

  return {
    value: lang,
    label: languageMap[lang] || lang,
  };
});

const CodeBlockComponent = ({ node, updateAttributes, editor }: NodeViewProps) => {
  const language = cast<string | null | undefined>(node.attrs.language);
  const { isEditable } = editor;

  return (
    <NodeViewWrapper as="pre" className="codeblock-lowlight">
      <div style={{ width: "fit-content", float: "right" }}>
        {isEditable ? (
          <select
            onChange={(e) => updateAttributes({ language: e.target.value })}
            defaultValue={language || "plaintext"}
            style={{
              lineHeight: "var(--spacer-4)",
              fontFamily: "var(--font-family)",
              paddingTop: "calc(var(--spacer-1) / 2)",
              paddingBottom: "calc(var(--spacer-1) / 2)",
            }}
          >
            {LANGUAGES.map((lang) => (
              <option key={lang.value} value={lang.value}>
                {lang.label}
              </option>
            ))}
          </select>
        ) : (
          <CopyToClipboard text={node.textContent}>
            <button
              className="link cursor-pointer all-unset"
              style={{ padding: "0 var(--spacer-1)" }}
              aria-label="Copy"
            >
              <Icon name="outline-duplicate" />
            </button>
          </CopyToClipboard>
        )}
      </div>
      <NodeViewContent as="code" />
    </NodeViewWrapper>
  );
};

export const CodeBlock = CodeBlockLowlight.extend({
  addOptions() {
    /* eslint-disable @typescript-eslint/consistent-type-assertions -- work around a tiptap bug */
    const parentOptions = (this.parent as (() => CodeBlockLowlightOptions) | undefined)?.();
    if (!parentOptions) return {} as CodeBlockLowlightOptions;
    /* eslint-enable */

    return {
      ...parentOptions,
      lowlight,
      defaultLanguage: "plaintext",
      HTMLAttributes: {
        ...parentOptions.HTMLAttributes,
      },
    };
  },
  addNodeView() {
    return ReactNodeViewRenderer(CodeBlockComponent);
  },
});
