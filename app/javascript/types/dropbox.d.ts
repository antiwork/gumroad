type DropboxFile = {
  id: string;
  link: string;
  bytes: number;
  name: string;
};

declare const Dropbox: {
  choose: (params: { linkType: "direct"; multiselect: boolean; success: (files: DropboxFile[]) => void }) => void;
  save: (options: {
    files: { url: string; filename: string | null }[];
    success?: () => void;
    progress?: () => void;
    cancel?: () => void;
    error?: () => void;
  }) => void;
};
interface Window {
  Dropbox: typeof Dropbox;
}
