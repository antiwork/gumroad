export type RichContent = {
  type?: string;
  attrs?: Record<string, unknown>;
  content?: RichContent[];
  marks?: Record<string, unknown>[];
  text?: string;
};

export type RichContentPage = {
  page_id: string;
  title: string | null;
  variant_id: string | null;
  description: RichContent | null;
  updated_at: string;
};
