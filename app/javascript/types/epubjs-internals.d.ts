declare module "epubjs/src/archive" {
  export const MAX_EPUB_ARCHIVE_BYTES: number;
  export const MAX_EPUB_ENTRY_COUNT: number;
  export const MAX_EPUB_ENTRY_BYTES: number;
  export const MAX_EPUB_EXPANDED_BYTES: number;

  export default class Archive {
    createUrl(path: string): Promise<string>;
    destroy(): void;
    getBlob(path: string): Promise<Blob>;
    getText(path: string): Promise<string>;
    maxEntryBytes: number;
    maxExpandedBytes: number;
    open(input: ArrayBuffer | ArrayBufferView | { byteLength: number } | string, isBase64?: boolean): Promise<unknown>;
    request(path: string, type?: string): Promise<unknown>;
    urlCache: Record<string, string>;
    zip: {
      loadAsync(input: unknown, options?: { base64?: boolean }): Promise<unknown>;
    };
  }
}

declare module "epubjs/src/resources" {
  export default class Resources {
    constructor(
      manifest: Record<string, { href: string; type: string }>,
      options: {
        archive: { getText: (path: string) => Promise<string> };
        replacements: string;
        resolver: (path: string) => string;
      },
    );

    createUrl(path: string): Promise<string>;
    createCssFile(path: string): Promise<string | undefined>;
    destroy(): void;
    replacementUrls: (string | null)[];
    replacements(): Promise<(string | null)[]>;
    substitute(content: string, url?: string): string;
  }
}

declare module "epubjs/src/managers/default" {
  type Section = {
    href?: string;
    index?: number;
    next: () => Section | undefined;
    prev: () => Section | undefined;
    properties: string[];
  };

  export default class DefaultViewManager {
    constructor(options: {
      queue: object;
      request: () => Promise<unknown>;
      settings: Record<string, unknown>;
      view: new () => object;
    });

    add: (section: Section, forceRight?: boolean) => Promise<unknown>;
    append: (section: Section, forceRight: boolean) => Promise<unknown>;
    clear: () => void;
    display(section: Section): Promise<void>;
    isPaginated: boolean;
    layout: { divisor: number; name: string };
    next(): Promise<void>;
    prepend: (section: Section, forceRight: boolean) => Promise<unknown>;
    prev(): Promise<void>;
    updateLayout: () => void;
    views: {
      find: (section: Section) => unknown;
      first: () => { section: Section };
      last: () => { section: Section };
      length: number;
      show: () => void;
    };
  }
}

declare module "epubjs/src/rendition" {
  export default class Rendition {
    _display(target?: string): Promise<unknown>;
    display(target?: string): Promise<unknown>;
    q: import("epubjs/src/utils/queue").default;
  }
}

declare module "epubjs/src/utils/queue" {
  export default class Queue {
    constructor(context: object);
    enqueue(task: (...args: unknown[]) => unknown, ...args: unknown[]): Promise<unknown>;
  }
}
