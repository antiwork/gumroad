# frozen_string_literal: true

require "spec_helper"

describe CdnDeletable do
  describe ".alive_in_cdn" do
    it "returns only those records which have `deleted_from_cdn_at` set to a NULL value" do
      create(:product_file, deleted_from_cdn_at: Time.current)
      product_file = create(:product_file)

      expect(ProductFile.alive_in_cdn.pluck(:id)).to eq([product_file.id])
    end
  end

  describe ".cdn_deletable" do
    it "only includes deleted records, with S3 url, alive in the CDN" do
      product_files = [
        create(:product_file),
        create(:product_file, deleted_at: Time.current),
        create(:product_file, deleted_at: Time.current, deleted_from_cdn_at: Time.current),
        create(:product_file, deleted_at: Time.current, url: "https://example.com", filetype: "link"),
      ]

      expect(ProductFile.cdn_deletable).to match_array([product_files[1]])
    end
  end

  describe "#deleted_from_cdn?" do
    it "returns `true` when `deleted_from_cdn_at` is a non-NULL value" do
      product_file = create(:product_file, deleted_from_cdn_at: Time.current)

      expect(product_file.deleted_from_cdn?).to eq(true)
    end

    it "returns `false` when `deleted_from_cdn_at` is a NULL value" do
      product_file = create(:product_file)

      expect(product_file.deleted_from_cdn?).to eq(false)
    end
  end

  describe "#mark_deleted_from_cdn" do
    it "sets the value of `deleted_from_cdn_at` to the current time" do
      product_file = create(:product_file)
      travel_to(Time.current) do
        product_file.mark_deleted_from_cdn
        expect(product_file.deleted_from_cdn_at.to_s).to eq(Time.current.utc.to_s)
      end
    end
  end
end
