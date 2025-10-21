# frozen_string_literal: true

require "spec_helper"

describe TwitterCards, :vcr do
  describe "#twitter_product_card" do
    it "renders a bunch of meta tags" do
      link = build(:product, unique_permalink: "abcABC")
      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to match("<meta property=\"twitter:card\" value=\"summary\" />")
      expect(metas).to match("twitter:title")
      expect(metas).to match(link.name)
      expect(metas).to match(link.price_formatted.delete("$"))
      expect(metas).to_not match("image")
      expect(metas).to_not match("creator")
    end

    it "renders preview if image" do
      link = build(:product, preview: fixture_file_upload("kFDzu.png", "image/png"))
      thumbnail = Thumbnail.new(product: link)
      blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
      blob.analyze
      thumbnail.file.attach(blob)
      thumbnail.save!
      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to match("<meta property=\"twitter:card\" value=\"summary_large_image\" />")
      expect(metas).to match("image")
      expect(metas).to match(link.main_preview.url)
    end

    it "renders twitter user if available" do
      user = build(:user, twitter_handle: "gumroad")
      link = build(:product, unique_permalink: "abcABC", user:)
      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to match("creator")
      expect(metas).to match("@gumroad")
    end

    it "falls back to the old twitter cards if the link doesn't have a preview image" do
      link = build(:product, filegroup: "archive", size: 10)
      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to_not match("<meta property=\"twitter:card\" value=\"product\" />")
      expect(metas).to match("<meta property=\"twitter:card\" value=\"summary\" />")
    end

    it "falls back to the old twitter cards if the link's preview isn't an image" do
      link = build(:product, filegroup: "archive", preview: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "thing.mov"), "video/quicktime"))
      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to_not match("<meta property=\"twitter:card\" value=\"product\" />")
      expect(metas).to match("<meta property=\"twitter:card\" value=\"player\" />")
    end

    it "does not uri escape the preview image url" do
      link = create(:product)
      create(:asset_preview, link:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/file with spaces.png")
      link.product_files << create(:product_file, link:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil1.png")
      link.save!
      link.reload

      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to match(link.main_preview.url)
    end

    it "does not uri escape the preview image url but it should html-escape it if necessary" do
      link = create(:product)
      create(:asset_preview, link:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/file_with_double_quotes\".png")
      link.product_files << create(:product_file, link:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil1.png")
      link.save!
      link.reload

      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to match(link.main_preview.url)
    end

    it "uses the card description if provided" do
      link = build(:product, unique_permalink: "abcABC")
      metas = TwitterCards.twitter_product_card(link, product_description: "This is a test description")
      expect(metas).to match('<meta property="twitter:description" value="This is a test description"')
    end

    it "uses the link description if no card description is provided" do
      link = build(:product, unique_permalink: "abcABC", description: "This is a test description")
      metas = TwitterCards.twitter_product_card(link)
      expect(metas).to match('<meta property="twitter:description" value="This is a test description"')
    end
  end

  describe "#twitter_post_card" do
    context "when post has no embedded images" do
      it "renders twitter meta tags for small summary" do
        post = build(:installment, name: "Friday dispatch", message: "<p>Important message</p>")
        metas = TwitterCards.twitter_post_card(post)
        expect(metas).to match('<meta property="twitter:domain" value="Gumroad" />')
        expect(metas).to match('<meta property="twitter:card" value="summary" />')
        expect(metas).to match('<meta property="twitter:title" value="Friday dispatch"')
        expect(metas).to match('<meta property="twitter:description" value="Important message"')
      end
    end

    context "when post has an embedded image" do
      it "renders twitter meta tags for large summary with image" do
        post = build(
          :installment,
          name: "Friday dispatch",
          message: <<~HTML.strip
            <p>Important message</p>
            <figure>
              <img src="path/to/image.jpg">
              <p class="figcaption">Image description</p>
            </figure>
          HTML
        )
        metas = TwitterCards.twitter_post_card(post)
        expect(metas).to match('<meta property="twitter:domain" value="Gumroad" />')
        expect(metas).to match('<meta property="twitter:card" value="summary_large_image" />')
        expect(metas).to match('<meta property="twitter:title" value="Friday dispatch"')
        expect(metas).to match('<meta property="twitter:description" value="Important message Image description"')
        expect(metas).to match('<meta property="twitter:image" value="path/to/image.jpg"')
        expect(metas).to match('<meta property="twitter:image:alt" value="Image description"')
      end
    end
  end
end
