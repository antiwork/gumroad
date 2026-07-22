# frozen_string_literal: true

require "spec_helper"

describe Onetime::DedupDuplicateUtmLinks do
  let(:seller) { create(:user) }

  # The race that created these duplicates bypassed the model validation, so the spec
  # does the same: build the duplicate and save it without validation.
  def create_duplicate_of(link)
    build(:utm_link,
          seller: link.seller,
          target_resource_type: link.target_resource_type,
          target_resource_id: link.target_resource_id,
          utm_source: link.utm_source,
          utm_medium: link.utm_medium,
          utm_campaign: link.utm_campaign,
          utm_term: link.utm_term,
          utm_content: link.utm_content,
          permalink: UtmLink.generate_permalink).tap { _1.save!(validate: false) }
  end

  describe ".process" do
    let!(:keeper) do
      create(:utm_link, seller:, target_resource_type: "profile_page", target_resource_id: nil,
                        utm_source: "facebook", utm_medium: "social", utm_campaign: "spring",
                        utm_term: nil, utm_content: nil,
                        first_click_at: 3.days.ago, last_click_at: 2.days.ago)
    end
    let!(:duplicate) { create_duplicate_of(keeper) }
    let!(:unrelated_link) { create(:utm_link, seller:) }

    let!(:keeper_visit) { create(:utm_link_visit, utm_link: keeper, browser_guid: "guid-a") }
    let!(:duplicate_visit) { create(:utm_link_visit, utm_link: duplicate, browser_guid: "guid-b") }
    let!(:duplicate_driven_sale) do
      create(:utm_link_driven_sale, utm_link: duplicate, utm_link_visit: duplicate_visit)
    end

    before do
      duplicate.update_columns(first_click_at: 4.days.ago, last_click_at: 1.day.ago)
    end

    it "does not change anything on a dry run" do
      expect do
        described_class.process
      end.to not_change { duplicate.reload.deleted_at }
        .and not_change { duplicate_visit.reload.utm_link_id }
        .and not_change { keeper.reload.total_clicks }
    end

    it "repoints visits and driven sales to the oldest link, merges click data, and soft-deletes the duplicate" do
      described_class.process(dry_run: false)

      expect(duplicate.reload).to be_deleted
      expect(keeper.reload).to be_alive

      expect(duplicate_visit.reload.utm_link_id).to eq(keeper.id)
      expect(duplicate_driven_sale.reload.utm_link_id).to eq(keeper.id)

      expect(keeper.total_clicks).to eq(2)
      expect(keeper.unique_clicks).to eq(2)
      expect(keeper.first_click_at).to be_within(1.second).of(4.days.ago)
      expect(keeper.last_click_at).to be_within(1.second).of(1.day.ago)
    end

    it "leaves non-duplicated links untouched" do
      described_class.process(dry_run: false)

      expect(unrelated_link.reload).to be_alive
    end

    it "merges all extra rows when a group has more than two duplicates" do
      second_duplicate = create_duplicate_of(keeper)

      described_class.process(dry_run: false)

      expect(duplicate.reload).to be_deleted
      expect(second_duplicate.reload).to be_deleted
      expect(keeper.reload).to be_alive
    end
  end
end
