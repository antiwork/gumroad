# frozen_string_literal: true

require "spec_helper"
require Rails.root.join("db/migrate/20261201000005_backfill_orphaned_shown_products_in_profile_sections").to_s

describe BackfillOrphanedShownProductsInProfileSections do
  subject(:migration) { described_class.new }

  let(:seller) { create(:user) }

  # Reproduce the pre-fix orphaned state directly: a soft-deleted product id
  # lingering in shown_products. We write it via update_columns so the new
  # Link#remove_from_profile_sections! callback can't strip it first.
  def orphan_section(shown:)
    section = create(:seller_profile_products_section, seller:, add_new_products: false)
    section.update_columns(json_data: section.json_data.merge("shown_products" => shown))
    section
  end

  it "strips soft-deleted product ids out of shown_products" do
    alive = create(:product, user: seller)
    deleted = create(:product, user: seller)
    deleted.update_columns(deleted_at: Time.current)
    section = orphan_section(shown: [alive.id, deleted.id])

    migration.up

    expect(section.reload.shown_products).to eq([alive.id])
  end

  it "leaves a section with only alive products untouched" do
    alive_one = create(:product, user: seller)
    alive_two = create(:product, user: seller)
    section = orphan_section(shown: [alive_one.id, alive_two.id])
    updated_at_before = section.reload.updated_at

    migration.up

    expect(section.reload.shown_products).to eq([alive_one.id, alive_two.id])
    expect(section.updated_at).to eq(updated_at_before)
  end
end
