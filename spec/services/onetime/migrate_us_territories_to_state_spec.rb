# frozen_string_literal: true

require "spec_helper"

describe Onetime::MigrateUsTerritoriesToState do
  describe ".process" do
    let(:seller) { create(:user) }

    def create_alive_uci(user, attrs)
      create(:user_compliance_info_empty, user:, **attrs)
    end

    it "creates a new alive UCI with country='United States' and state='PR' for Puerto Rico sellers" do
      pr_user = create(:user)
      create_alive_uci(pr_user, country: "Puerto Rico", state: nil)

      described_class.process

      alive = pr_user.reload.alive_user_compliance_info
      expect(alive.country).to eq("United States")
      expect(alive.state).to eq("PR")
    end

    it "leaves sellers in other US outlying areas (Guam, USVI, etc.) alone — Stripe does not support them" do
      gu_user = create(:user)
      vi_user = create(:user)
      create_alive_uci(gu_user, country: "Guam", state: nil)
      create_alive_uci(vi_user, country: "Virgin Islands, U.S.", state: nil)

      described_class.process

      expect(gu_user.reload.alive_user_compliance_info.country).to eq("Guam")
      expect(vi_user.reload.alive_user_compliance_info.country).to eq("Virgin Islands, U.S.")
    end

    it "soft-deletes the previously alive territory UCI" do
      create_alive_uci(seller, country: "Puerto Rico")
      old_uci = seller.alive_user_compliance_info

      described_class.process

      expect(old_uci.reload.deleted_at).to be_present
      expect(seller.alive_user_compliance_info.id).not_to eq(old_uci.id)
    end

    it "does not enqueue HandleNewUserComplianceInfoWorker for migrated rows" do
      create_alive_uci(seller, country: "Puerto Rico")

      expect { described_class.process }.not_to change(HandleNewUserComplianceInfoWorker.jobs, :size)
    end

    it "is idempotent — running twice does not create extra UCI rows" do
      create_alive_uci(seller, country: "Puerto Rico")

      described_class.process
      count_after_first_run = seller.user_compliance_infos.count

      described_class.process

      expect(seller.user_compliance_infos.count).to eq(count_after_first_run)
      expect(seller.alive_user_compliance_info.country).to eq("United States")
      expect(seller.alive_user_compliance_info.state).to eq("PR")
    end

    it "flips business_country/business_state only when business_country was the same territory" do
      pr_personal_us_business = create(:user)
      pr_both = create(:user)

      create_alive_uci(pr_personal_us_business,
                       country: "Puerto Rico", state: nil,
                       business_country: "United States", business_state: "CA")
      create_alive_uci(pr_both,
                       country: "Puerto Rico", state: nil,
                       business_country: "Puerto Rico", business_state: "PR")

      described_class.process

      mixed = pr_personal_us_business.reload.alive_user_compliance_info
      expect(mixed.country).to eq("United States")
      expect(mixed.state).to eq("PR")
      expect(mixed.business_country).to eq("United States")
      expect(mixed.business_state).to eq("CA")

      flipped = pr_both.reload.alive_user_compliance_info
      expect(flipped.country).to eq("United States")
      expect(flipped.state).to eq("PR")
      expect(flipped.business_country).to eq("United States")
      expect(flipped.business_state).to eq("PR")
    end

    it "leaves UCIs from supported, non-territory countries alone" do
      uk_user = create(:user)
      create_alive_uci(uk_user, country: "United Kingdom", state: nil)
      original_uci = uk_user.alive_user_compliance_info

      described_class.process

      expect(uk_user.reload.alive_user_compliance_info.id).to eq(original_uci.id)
      expect(uk_user.alive_user_compliance_info.country).to eq("United Kingdom")
    end

    it "skips a UCI that is no longer the user's alive UCI (race protection)" do
      create_alive_uci(seller, country: "Puerto Rico")
      stale_uci = seller.alive_user_compliance_info
      stale_uci.mark_deleted(validate: false)
      create_alive_uci(seller, country: "United Kingdom", state: nil)

      expect { described_class.process }.not_to(change { seller.reload.alive_user_compliance_info.country })
      expect(seller.alive_user_compliance_info.country).to eq("United Kingdom")
    end
  end
end
