interface ObjectConstructor {
  keys<T>(o: T): (keyof T)[];
  entries<T extends object, K extends keyof T>(o: T): [K, T[K]][];
  fromEntries<T, K extends PropertyKey>(entries: Iterable<readonly [K, T]>): { [k in K]: T };
}

interface String {
  split(separator: string | RegExp): [string, ...string[]];
}

type Tuple<T, N extends number> = N extends N ? (number extends N ? T[] : $TupleOf<T, N, []>) : never;
type $TupleOf<T, N extends number, R extends unknown[]> = R["length"] extends N ? R : $TupleOf<T, N, [T, ...R]>;

declare namespace NodeJS {
  interface Process {
    env: {
      ROOT_DOMAIN: string;
      SHORT_DOMAIN: string;
      DOMAIN: string;
      PROTOCOL: string;
      NODE_ENV: string;
    };
  }
}

declare namespace React {
  interface HTMLAttributes<T> extends AriaAttributes, DOMAttributes<T> {
    inert?: boolean | undefined;
  }
}

declare const SSR: boolean;

// IconName is generated to app/javascript/types/icons.d.ts at build time; provide a fallback for TS
type IconName = string;

// Provide a global Routes declaration so TS sees it everywhere
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- Routes is generated dynamically by Rails and has dynamic method names
declare const Routes: Record<string, any>;
