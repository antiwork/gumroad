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
      purchase = create(:free_purchase, seller:, link: create(:product, user: seller, price_cents: 0))
      create(:utm_link_driven_sale, utm_link: duplicate, utm_link_visit: duplicate_visit, purchase:)
    end

    before do
      duplicate.update_columns(first_click_at: 4.days.ago, last_click_at: 1.day.ago)
      # Don't actually wait out the straggler grace period in specs.
      allow_any_instance_of(described_class).to receive(:sleep)
    end

    it "does not change anything on a dry run" do
      expect do
        described_class.process
      end.to not_change { duplicate.reload.deleted_at }
        .and not_change { duplicate_visit.reload.utm_link_id }
        .and not_change { keeper.reload.total_clicks }
    end

    it "sweeps up visits committed by requests that raced the merge and recounts the keeper" do
      # Simulate a request that loaded the duplicate while it was still alive and
      # committed its visit only after the merge transaction ran: inject the late visit
      # during the grace-period wait, right before the straggler sweep.
      late_visit = nil
      allow_any_instance_of(described_class).to receive(:sleep) do
        late_visit ||= create(:utm_link_visit, browser_guid: "guid-late").tap do
          _1.update_column(:utm_link_id, duplicate.id)
        end
      end

      described_class.process(dry_run: false)

      expect(late_visit.reload.utm_link_id).to eq(keeper.id)
      expect(keeper.reload.total_clicks).to eq(3)
      expect(keeper.unique_clicks).to eq(3)
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
