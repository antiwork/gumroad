# frozen_string_literal: true

require "spec_helper"

def uploaded_file(name)
  Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", name), MIME::Types.type_for(name).first)
end

describe Product::Preview do
  before do
    @bad_file = uploaded_file("other.garbage")
    @jpg_file = uploaded_file("test-small.jpg")
    @mov_file = uploaded_file("thing.mov")
    @png_file = uploaded_file("kFDzu.png")
  end

  describe "Asset Previews", :vcr do
    describe "with attached files" do
      it "has default attributes if no preview exists" do
        link = create(:product)
        expect(link.main_preview).to be(nil)
        expect(link.preview_image_path?).to be(false)
        expect(link.preview_video_path?).to be(false)
        expect(link.preview_oembed_url).to be(nil)
        expect(link.preview_url).to be(nil)
      end

      it "saves existing preview image as its main asset preview" do
        link = build(:product)
        expect { link.preview = @png_file }.to change { AssetPreview.alive.count }.by(1)
        expect(link.main_preview.file.filename.to_s).to eq(@png_file.original_filename)
        expect(link.preview_width).to eq(670)
        expect(link.preview_height).to eq(210)
      end

      it "saves a new preview image with correct attributes" do
        link = create(:product)
        expect do
          link.preview = @png_file
          link.save!
        end.to change { link.main_preview }.from(nil)
        expect(link.main_preview.file.filename.to_s).to eq(@png_file.original_filename)
        expect(HTTParty.head(link.preview_url).code).to eq 200
        expect(link.preview_image_path?).to be(true)
        expect(link.preview_video_path?).to be(false)
      end

      it "saves a new preview video with correct attributes" do
        link = create(:product)
        expect do
          link.preview = @mov_file
          link.save!
        end.to change { link.main_preview }.from(nil)
        expect(link.main_preview.file.filename.to_s).to eq(@mov_file.original_filename)
        expect(HTTParty.get(link.reload.preview_url).code).to eq 200
        expect(link.preview_image_path?).to be(false)
        expect(link.preview_video_path?).to be(true)
      end

      it "does not save an arbitrary filetype" do
        link = create(:product)
        expect do
          expect do
            link.preview = @bad_file
            link.save!
          end.to raise_error(ActiveRecord::RecordInvalid)
        end.to_not change { link.main_preview }
      end

      it "creates a new asset preview when preview is changed" do
        link = create(:product, preview: @png_file)
        expect(link.display_asset_previews.last.file.filename.to_s).to match(/#{ @png_file.original_filename }$/)
        link.preview = @jpg_file
        link.save!
        expect(link.display_asset_previews.last.file.filename.to_s).to match(/#{ @jpg_file.original_filename }$/)
        expect(link.display_asset_previews.last.display_width).to eq(25)
        expect(link.display_asset_previews.last.display_height).to eq(25)
      end

      it "does not create a product preview when an existing product with no asset previews is saved" do
        link = create(:product, preview: nil, preview_url: nil)
        expect do
          link.name = "A link by any other name would preview as sweet"
          link.save!
        end.to_not change { link.asset_previews.alive.count }.from(0)
      end

      it "does nothing if a product has an asset preview and its preview is unchanged" do
        link = create(:product, preview: @png_file, created_at: 1.day.ago, updated_at: 1.day.ago)
        expect do
          link.update(name: "This is what happens when we change the name of a product")
        end.to_not change { link.main_preview.updated_at }
      end

      it "deletes an asset preview" do
        link = create(:product, preview: @png_file)
        expect { link.preview = nil }.to change { link.main_preview }.to(nil)
      end
    end

    describe "with embeddable preview URLs" do
      it "creates with correct dimensions from a fully-qualified URL" do
        link = create(:product, preview_url: "https://www.youtube.com/watch?v=apiu3pTIwuY")
        expect(link.preview_oembed_url).to eq("https://www.youtube.com/embed/apiu3pTIwuY?feature=oembed&showinfo=0&controls=0&rel=0&enablejsapi=1")
        expect(link.preview_width).to eq(356)
        expect(link.preview_height).to eq(200)
      end

      it "creates with a relative URL" do
        link = create(:product, preview_url: "https://www.youtube.com/watch?v=apiu3pTIwuY")
        expect(link.preview_oembed_url).to eq("https://www.youtube.com/embed/apiu3pTIwuY?feature=oembed&showinfo=0&controls=0&rel=0&enablejsapi=1")
      end

      it "deletes an asset preview URL" do
        link = create(:product, preview_url: "https://www.youtube.com/watch?v=apiu3pTIwuY")
        expect do
          link.preview = ""
          link.save!
        end.to change { link.main_preview }.to(nil)
      end
    end

    context "preview is from Unsplash" do
      let!(:asset_preview) { create(:asset_preview, unsplash_url: "https://images.unsplash.com/example.jpeg", attach: false) }

      it "returns the correct URLs" do
        product = asset_preview.link
        expect(product.main_preview).to eq(asset_preview)
        expect(product.preview_image_path?).to eq(true)
        expect(product.preview_video_path?).to eq(false)
        expect(product.preview_oembed_url).to eq(nil)
        expect(product.preview_url).to eq(asset_preview.unsplash_url)
      end
    end
  end
end
