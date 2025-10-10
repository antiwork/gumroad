import "react";

declare module "react" {
  export interface CSSProperties {
    "--color"?: string;
    "--accent"?: string;
    "--contrast-accent"?: string;
    "--filled"?: string;
    "--contrast-filled"?: string;
    "--primary"?: string;
    "--body-bg"?: string;
    "--contrast-primary"?: string;
  }
}
