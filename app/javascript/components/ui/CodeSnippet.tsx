import React from "react";

import { classNames } from "$app/utils/classNames";

type CodeSnippetProps = {
  caption?: string;
  children: React.ReactNode;
};

const CodeSnippet: React.FC<CodeSnippetProps> = ({ caption, children }) => (
  <figure className="overflow-hidden rounded border border-border bg-background">
    {caption ? <figcaption className="p-4">{caption}</figcaption> : null}
    <pre className={classNames("overflow-x-auto bg-muted-foreground p-4", caption && "border-t border-border")}>
      <code className="whitespace-pre">{children}</code>
    </pre>
  </figure>
);

export default CodeSnippet;
