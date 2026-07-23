# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillTaggingsCountOnTags do
  describe ".process" do
    # Simulates a write from a process without the counter-cache callbacks
    # (e.g. an old app server mid rolling deploy): the join row exists but
    # tags.taggings_count was never touched.
    def create_tagging_without_counter(tag, product)
      ProductTagging.insert_all([{ tag_id: tag.id, product_id: product.id, created_at: Time.current, updated_at: Time.current }])
    end

    it "recomputes counts from product_taggings, fixing drifted counters" do
      tag = create(:tag, name: "capybara")
      2.times { create_tagging_without_counter(tag, create(:product)) }
      expect(tag.reload.taggings_count).to eq(0)

      described_class.process

      expect(tag.reload.taggings_count).to eq(2)
    end

    it "resets counters for tags with no taggings, overwriting stale values" do
      tag = create(:tag, name: "walrus")
      Tag.where(id: tag.id).update_all(taggings_count: 99)

      described_class.process

      expect(tag.reload.taggings_count).to eq(0)
    end

    it "is idempotent across repeated runs" do
      tag = create(:tag, name: "lemur")
      create_tagging_without_counter(tag, create(:product))

      described_class.process
      described_class.process

      expect(tag.reload.taggings_count).to eq(1)
    end

    it "respects id bounds" do
      first = create(:tag, name: "aardvark")
      second = create(:tag, name: "zebra")
      create_tagging_without_counter(first, create(:product))
      create_tagging_without_counter(second, create(:product))

      described_class.process(start_tag_id: second.id)

      expect(first.reload.taggings_count).to eq(0)
      expect(second.reload.taggings_count).to eq(1)
    end
  end
end
