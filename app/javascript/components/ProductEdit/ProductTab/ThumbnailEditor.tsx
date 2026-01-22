import { DirectUpload } from "@rails/activestorage";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Thumbnail, ThumbnailPayload, createThumbnail, deleteThumbnail } from "$app/data/thumbnails";
import { AssetPreview, ProductNativeType } from "$app/parsers/product";
import FileUtils, { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { getImageDimensionsFromFile } from "$app/utils/image";
import { assertResponseError } from "$app/utils/request";

import { ImageUploader } from "$app/components/ImageUploader";
import { showAlert } from "$app/components/server-components/Alert";

const nativeTypeThumbnails = require.context("$assets/images/native_types/thumbnails/");

const MIN_SIDE_DIMENSION = 600;
const MEGABYTE = 1024 * 1024;
const MAX_FILE_SIZE = 5 * MEGABYTE;
export class ValidationError extends Error {
  constructor(message = "Loại file không hợp lệ.") {
    super(message);
  }
}

const validateFile = async (file: File) => {
  if (!FileUtils.isFileNameExtensionAllowed(file.name, ALLOWED_EXTENSIONS)) throw new ValidationError();

  if (file.size > MAX_FILE_SIZE)
    throw new ValidationError("Không thể xử lý thumbnail, vui lòng tải lên ảnh có kích thước nhỏ hơn 5 MB.");

  const dimensions = await getImageDimensionsFromFile(file).catch(() => null);
  if (!dimensions) throw new ValidationError();
  if (dimensions.height !== dimensions.width) throw new ValidationError("Ảnh phải là hình vuông.");

  if (dimensions.height < MIN_SIDE_DIMENSION) throw new ValidationError("Ảnh phải có kích thước ít nhất 600x600px.");
};

export const coverUrlForThumbnail = (covers: AssetPreview[]) =>
  covers.find((cover) => cover.type === "image" || cover.type === "unsplash")?.url ?? null;

export const ThumbnailEditor = ({
  covers,
  thumbnail,
  setThumbnail,
  permalink,
  nativeType,
}: {
  covers: AssetPreview[];
  thumbnail: Thumbnail | null;
  setThumbnail: (thumbnail: Thumbnail | null) => void;
  permalink: string;
  nativeType: ProductNativeType;
}) => {
  const saveThumbnail = async (thumbnailPayload: ThumbnailPayload) => {
    try {
      const thumbnail = await createThumbnail(permalink, thumbnailPayload);
      setThumbnail(thumbnail);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  const removeThumbnail = async (guid: string) => {
    try {
      await deleteThumbnail(permalink, guid);
      showAlert("Đã xóa thumbnail.", "success");
      setThumbnail(null);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  return (
    <section className="p-4! md:p-8!">
      <div className="flex items-center justify-between">
        <h2>Thumbnail</h2>
        <a href="/help/article/60-adding-a-cover-image" target="_blank" rel="noreferrer">
          Tìm hiểu thêm
        </a>
      </div>
      <ImageUploader
        imageAlt="Thumbnail image"
        imageUrl={thumbnail?.url ?? null}
        allowedExtensions={ALLOWED_EXTENSIONS}
        helpText="Ảnh này xuất hiện trên Thư viện, Khám phá và trang Hồ sơ. Ảnh của bạn nên là hình vuông, ít nhất 600x600px, và ở định dạng JPG, PNG hoặc GIF."
        onRemove={() => void removeThumbnail(thumbnail?.guid ?? "")}
        defaultImageUrl={coverUrlForThumbnail(covers) ?? cast<string>(nativeTypeThumbnails(`./${nativeType}.svg`))}
        onSelectFile={(file) =>
          new Promise((resolve, reject) => {
            validateFile(file).then(
              () => {
                new DirectUpload(file, Routes.rails_direct_uploads_path()).create((error, blob) => {
                  if (error) return resolve(showAlert(error.message, "error"));
                  saveThumbnail({ type: "file", signedBlobId: blob.signed_id }).then(resolve, (e: unknown) => {
                    assertResponseError(e);
                    reject(e);
                  });
                });
              },
              (e: unknown) => {
                if (e instanceof ValidationError) return resolve(showAlert(e.message, "error"));
                throw e;
              },
            );
          })
        }
      />
    </section>
  );
};
