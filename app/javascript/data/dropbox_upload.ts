import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type ResponseDropboxFile = {
  external_id: string;
  name: string;
  bytes: number;
  s3_url: string | null;
  state: "in_progress" | "successfully_uploaded" | "cancelled" | "failed" | "deleted";
  dropbox_url: string;
};

export async function uploadDropboxFile(permalink: string, file: DropboxFile) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.create_dropbox_file_path(),
    data: { ...file, link_id: permalink },
  });
  if (!response.ok) throw new ResponseError();
  return cast<{ dropbox_file: ResponseDropboxFile }>(await response.json());
}

export async function cancelDropboxFileUpload(id: string) {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.cancel_dropbox_file_upload_path(id),
  });
  if (!response.ok) throw new ResponseError();
  const json = cast<{ success: false } | { dropbox_file: ResponseDropboxFile; success: true }>(await response.json());
  if (!json.success) throw new ResponseError();
  return json.dropbox_file;
}

export async function fetchDropboxFiles(permalink: string) {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.dropbox_files_path({ link_id: permalink }),
  });
  if (!response.ok) throw new ResponseError();
  return cast<{ dropbox_files: ResponseDropboxFile[] }>(await response.json());
}
