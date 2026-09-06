# frozen_string_literal: true

require "spec_helper"

describe "primary pin boundaries" do
  def writing_block?
    ApplicationRecord.connected_to_stack.any? { |entry| entry[:role] == :writing && entry[:klasses].include?(ApplicationRecord) }
  end

  [[:handle_new_bank_account, :update_bank_account], [:handle_new_user_compliance_info, :update_account]].each do |callback, update|
    it "keeps #{callback} pinned through dependent account updates" do
      user = double("user", has_stripe_account_connected?: false, stripe_account: double("account"))
      record = double("new record", user:)
      expect(StripeMerchantAccountManager).to receive(update) do
        expect(writing_block?).to eq(true)
      end

      StripeMerchantAccountManager.public_send(callback, record)
    end
  end

  [true, false].each do |dry_run|
    it "#{dry_run ? "releases" : "pins"} merchant cleanup discovery" do
      service = Onetime::CleanupWedgedStripeMerchantAccounts.new
      expect(service).to receive(:candidates) do
        expect(writing_block?).to eq(!dry_run)
        MerchantAccount.none
      end
      service.process(dry_run:)
    end

    [:process, :process_url_divergent, :process_commission_divergent].each do |method|
      it "#{dry_run ? "releases" : "pins"} affiliate #{method} discovery" do
        service = Onetime::DeduplicateProductAffiliates.new
        allow(service).to receive(:duplicate_pairs) do
          expect(writing_block?).to eq(!dry_run)
          []
        end
        allow(service).to receive(:report_remaining_duplicates)
        service.public_send(method, dry_run:)
      end
    end
  end
end
