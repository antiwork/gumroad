import { DirectUpload } from "@rails/activestorage";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Progress } from "$app/components/Progress";
import { showAlert } from "$app/components/server-components/Alert";

interface ImageUploadProps {
  imageUrl: string | null;
  onImageUploaded: (signedBlobId: string, imageUrl: string) => void;
  onImageRemoved: () => void;
  disabled?: boolean;
}

interface UploadBlob {
  signed_id: string;
  key: string;
}

const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB
const ALLOWED_TYPES = ["image/jpeg", "image/png", "image/gif"];
const MIN_DIMENSIONS = 600; // 600x600px minimum

export const ImageUpload: React.FC<ImageUploadProps> = ({
  imageUrl,
  onImageUploaded,
  onImageRemoved,
  disabled = false
}) => {
  const [uploading, setUploading] = React.useState(false);
  const fileInputRef = React.useRef<HTMLInputElement>(null);

  const validateImageDimensions = (file: File): Promise<boolean> => {
    return new Promise((resolve) => {
      const img = new Image();
      img.onload = () => {
        resolve(img.width >= MIN_DIMENSIONS && img.height >= MIN_DIMENSIONS);
      };
      img.src = URL.createObjectURL(file);
    });
  };

  const handleFileSelect = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    if (!file) return;

    // Validate file type
    if (!ALLOWED_TYPES.includes(file.type)) {
      showAlert("Please upload a valid image file (JPG, PNG, or GIF).", "error");
      return;
    }

    // Validate file size
    if (file.size > MAX_FILE_SIZE) {
      showAlert("Image must be smaller than 5MB.", "error");
      return;
    }

    // Validate dimensions
    const validDimensions = await validateImageDimensions(file);
    if (!validDimensions) {
      showAlert("Image must be at least 600x600 pixels.", "error");
      return;
    }

    setUploading(true);

    try {
      const upload = new DirectUpload(file, Routes.rails_direct_uploads_path());
      
      upload.create((error: Error | null, blob: UploadBlob) => {
        if (error) {
          showAlert("Failed to upload image. Please try again.", "error");
          console.error("Upload error:", error);
        } else {
          // Get the CDN URL for the uploaded image
          const cdnUrl = Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key });
          onImageUploaded(blob.signed_id, cdnUrl);
          showAlert("Image uploaded successfully!", "success");
        }
        setUploading(false);
      });
    } catch (error) {
      showAlert("Failed to upload image. Please try again.", "error");
      console.error("Upload error:", error);
      setUploading(false);
    }

    // Clear the input
    if (fileInputRef.current) {
      fileInputRef.current.value = "";
    }
  };

  const handleRemoveImage = () => {
    onImageRemoved();
  };

  const handleUploadClick = () => {
    fileInputRef.current?.click();
  };

  return (
    <div>
      <h2 className="text-xl font-medium mb-4">Image</h2>
      
      {uploading ? (
        <div className="border rounded p-4">
          <div className="flex items-center justify-center gap-3 py-6" role="status" aria-label="Uploading image">
            <Progress width="2rem" />
            <span className="text-base">Uploading...</span>
          </div>
        </div>
      ) : imageUrl ? (
        <div className="border rounded overflow-hidden">
          <div className="relative">
            <img 
              src={imageUrl} 
              alt="Custom widget image" 
              className="w-full aspect-square object-cover"
            />
            <Button
              className="absolute top-2 right-2 p-1 min-w-0 rounded-full bg-black/50 hover:bg-black/70"
              color="danger"
              onClick={handleRemoveImage}
              disabled={disabled}
              aria-label="Remove image"
            >
              <Icon name="trash2" className="w-4 h-4" />
            </Button>
          </div>
        </div>
      ) : (
        <div className="border-2 border-dashed rounded p-4">
          <input
            ref={fileInputRef}
            type="file"
            accept={ALLOWED_TYPES.join(",")}
            onChange={handleFileSelect}
            className="hidden"
            disabled={disabled}
          />
          <div className="text-center py-8">
            <Button
              onClick={handleUploadClick}
              disabled={disabled}
              color="primary"
              className="inline-flex items-center gap-2 mb-4"
              aria-label="Upload image"
            >
              <Icon name="upload-fill" className="w-4 h-4" />
              Upload
            </Button>
            <p className="text-sm text-gray-600">
              Your image should be square, at least 600x600px, and<br />
              JPG, PNG or GIF format.
            </p>
          </div>
        </div>
      )}
    </div>
  );
};