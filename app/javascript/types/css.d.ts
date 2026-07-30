import "react";

declare module "react" {
  export interface CSSProperties {
    "--color"?: string;
    "--accent"?: string;
    "--contrast-accent"?: string;
    "--accent-with-text"?: string;
    "--filled"?: string;
    "--contrast-filled"?: string;
    "--primary"?: string;
    "--body-bg"?: string;
    "--contrast-primary"?: string;
    "--color-body"?: string;
    "--color-background"?: string;
    "--color-foreground"?: string;
    "--border-alpha"?: string;
    "--color-border"?: string;
    "--color-accent"?: string;
    "--color-accent-foreground"?: string;
    "--color-accent-with-text"?: string;
    "--color-primary"?: string;
    "--color-primary-foreground"?: string;
    "--color-active-bg"?: string;
    "--color-muted"?: string;
  }
}
