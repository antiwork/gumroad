# frozen_string_literal: true

require "test_helper"

class CdnDeletableTest < ActiveSupport::TestCase
  self.described_class = CdnDeletable



  context_ CdnDeletable do
  context_ ".alive_in_cdn" do
  test "returns only those records which have `deleted_from_cdn_at` set to a NULL value" do
        create(:product_file, deleted_from_cdn_at: Time.current)
        product_file = create(:product_file)

        expect(ProductFile.alive_in_cdn.pluck(:id)).to eq([product_file.id])
      end
    end

  context_ ".cdn_deletable" do
  test "only includes deleted records, with S3 url, alive in the CDN" do
        product_files = [
          create(:product_file),
          create(:product_file, deleted_at: Time.current),
          create(:product_file, deleted_at: Time.current, deleted_from_cdn_at: Time.current),
          create(:product_file, deleted_at: Time.current, url: "https://example.com", filetype: "link"),
        ]

        expect(ProductFile.cdn_deletable).to match_array([product_files[1]])
      end
    end

  context_ "#deleted_from_cdn?" do
  test "returns `true` when `deleted_from_cdn_at` is a non-NULL value" do
        product_file = create(:product_file, deleted_from_cdn_at: Time.current)

        expect(product_file.deleted_from_cdn?).to eq(true)
      end

  test "returns `false` when `deleted_from_cdn_at` is a NULL value" do
        product_file = create(:product_file)

        expect(product_file.deleted_from_cdn?).to eq(false)
      end
    end

  context_ "#mark_deleted_from_cdn" do
  test "sets the value of `deleted_from_cdn_at` to the current time" do
        product_file = create(:product_file)
        travel_to(Time.current) do
          product_file.mark_deleted_from_cdn
          expect(product_file.deleted_from_cdn_at.to_s).to eq(Time.current.utc.to_s)
        end
      end
    end
  end
end
