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
  interface ImgHTMLAttributes<T> extends HTMLAttributes<T> {
    fetchpriority?: HTMLImageElement["fetchPriority"];
  }
}

declare const SSR: boolean;
