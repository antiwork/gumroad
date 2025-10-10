// eslint-disable-next-line @typescript-eslint/no-unused-vars -- we merge into this interface, but the rule does not detect this properly
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
