# frozen_string_literal: true

require "rails_helper"

RSpec.describe FileStorageService do
  describe ".duplicate_blob" do
    it "creates a duplicate of an existing file" do
      user = create(:user)
      product = create(:digital_product, user: user)
      
      # Setup a file attachment
      attachment = fixture_file_upload("files/small.png", "image/png")
      product.build_thumbnail
      product.thumbnail.file.attach(attachment)
      product.thumbnail.save!
      
      expect(product.thumbnail.file).to be_attached
      
      # Duplicate the blob
      duplicate_blob = FileStorageService.duplicate_blob(product.thumbnail.file)
      
      expect(duplicate_blob).to be_present
      expect(duplicate_blob.filename).to eq(product.thumbnail.file.filename)
      expect(duplicate_blob.content_type).to eq(product.thumbnail.file.content_type)
      expect(duplicate_blob.byte_size).to eq(product.thumbnail.file.byte_size)
    end
    
    it "returns nil when the source file is not attached" do
      user = create(:user)
      product = create(:digital_product, user: user)
      
      product.build_thumbnail
      product.thumbnail.save!
      
      expect(product.thumbnail.file).not_to be_attached
      
      duplicate_blob = FileStorageService.duplicate_blob(product.thumbnail.file)
      expect(duplicate_blob).to be_nil
    end
  end
  
  describe ".duplicate_attachment" do
    it "duplicates an attachment from source to target" do
      user = create(:user)
      product = create(:digital_product, user: user)
      duplicated_product = create(:digital_product, user: user)
      
      # Setup source attachment
      attachment = fixture_file_upload("files/small.png", "image/png")
      product.build_thumbnail
      product.thumbnail.file.attach(attachment)
      product.thumbnail.save!
      
      # Setup target entity to receive attachment
      duplicated_product.build_thumbnail
      duplicated_product.thumbnail.save!
      
      expect {
        FileStorageService.duplicate_attachment(product.thumbnail.file, duplicated_product.thumbnail.file)
      }.to change { ActiveStorage::Blob.count }.by(1)
      
      expect(duplicated_product.thumbnail.file).to be_attached
      expect(duplicated_product.thumbnail.file.filename).to eq(product.thumbnail.file.filename)
    end
  end
end