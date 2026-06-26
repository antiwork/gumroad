# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillOrphanedShownProductsInProfileSections do
  describe ".process" do
    let(:seller) { create(:user) }

    # Reproduce the pre-fix orphaned state directly: dead product ids lingering in
    # shown_products. Written via update_columns so the Link#remove_from_profile_sections!
    # callback can't strip them first, and with add_new_products disabled so creating
    # products doesn't auto-add them.
    def section_with_shown(shown)
      section = create(:seller_profile_products_section, seller:, add_new_products: false)
      section.update_columns(json_data: section.json_data.merge("shown_products" => shown))
      section
    end

    it "strips soft-deleted product ids from shown_products" do
      alive = create(:product, user: seller)
      deleted = create(:product, user: seller)
      deleted.update_columns(deleted_at: Time.current)
      section = section_with_shown([alive.id, deleted.id])

      expect(described_class.process).to eq(1)

      expect(section.reload.shown_products).to eq([alive.id])
    end

    it "leaves a section with only alive products untouched" do
      alive_one = create(:product, user: seller)
      alive_two = create(:product, user: seller)
      section = section_with_shown([alive_one.id, alive_two.id])
      updated_at_before = section.reload.updated_at

      expect(described_class.process).to eq(0)

      expect(section.reload.shown_products).to eq([alive_one.id, alive_two.id])
      expect(section.updated_at).to eq(updated_at_before)
    end

    it "is idempotent across repeated runs" do
      alive = create(:product, user: seller)
      deleted = create(:product, user: seller)
      deleted.update_columns(deleted_at: Time.current)
      section = section_with_shown([alive.id, deleted.id])

      described_class.process
      expect(described_class.process).to eq(0)
      expect(section.reload.shown_products).to eq([alive.id])
    end

    it "skips malformed legacy rows without aborting the run" do
      malformed = create(:seller_profile_products_section, seller:, add_new_products: false)
      malformed.update_columns(json_data: nil)
      alive = create(:product, user: seller)
      deleted = create(:product, user: seller)
      deleted.update_columns(deleted_at: Time.current)
      valid = section_with_shown([alive.id, deleted.id])

      expect { expect(described_class.process).to eq(1) }.not_to raise_error

      expect(valid.reload.shown_products).to eq([alive.id])
    end
  end
end
