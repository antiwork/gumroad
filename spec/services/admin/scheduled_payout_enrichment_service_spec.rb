# frozen_string_literal: true

require "spec_helper"

describe Admin::ScheduledPayoutEnrichmentService do
  describe "#call" do
    let(:merchant_account) { create(:merchant_account, user: nil) }

    it "returns an empty hash for an empty input" do
      expect(described_class.new([]).call).to eq({})
    end

    it "counts alive products only" do
      seller = create(:compliant_user)
      create_list(:product, 2, user: seller)
      create(:product, user: seller, deleted_at: Time.current)
      scheduled_payout = create(:scheduled_payout, user: seller)

      enrichment = described_class.new([scheduled_payout]).call.fetch(seller.id)

      expect(enrichment[:product_count]).to eq(2)
    end

    it "counts alive direct affiliates and collaborators granted by the seller" do
      seller = create(:compliant_user)
      create_list(:direct_affiliate, 2, seller:)
      create(:collaborator, seller:)
      create(:direct_affiliate, seller:, deleted_at: Time.current)
      create(:collaborator, seller:, deleted_at: Time.current)
      seller.global_affiliate.update_column(:seller_id, seller.id)
      scheduled_payout = create(:scheduled_payout, user: seller)

      enrichment = described_class.new([scheduled_payout]).call.fetch(seller.id)

      expect(enrichment[:incoming_affiliate_count]).to eq(3)
    end

    it "sums unpaid balances only and formats the total" do
      seller = create(:compliant_user)
      create(:balance, user: seller, merchant_account:, amount_cents: 1_234, state: "unpaid")
      create(:balance, user: seller, merchant_account:, amount_cents: 11_111, state: "unpaid")
      create(:balance, user: seller, merchant_account:, amount_cents: 99_999, state: "processing")
      create(:balance, user: seller, merchant_account:, amount_cents: 99_999, state: "paid")
      create(:balance, user: seller, merchant_account:, amount_cents: 99_999, state: "forfeited")
      scheduled_payout = create(:scheduled_payout, user: seller)

      enrichment = described_class.new([scheduled_payout]).call.fetch(seller.id)

      expect(enrichment[:unpaid_balance_cents]).to eq(12_345)
      expect(enrichment[:unpaid_balance_formatted]).to eq("$123.45")
    end

    it "formats zero unpaid balance" do
      seller = create(:compliant_user)
      scheduled_payout = create(:scheduled_payout, user: seller)

      enrichment = described_class.new([scheduled_payout]).call.fetch(seller.id)

      expect(enrichment[:unpaid_balance_cents]).to eq(0)
      expect(enrichment[:unpaid_balance_formatted]).to eq("$0.00")
    end

    it "returns the top three categories by product count with a stable tie-breaker" do
      seller = create(:compliant_user)
      top_taxonomy = create(:taxonomy, slug: "top")
      second_taxonomy = create(:taxonomy, slug: "second")
      tied_first_taxonomy = create(:taxonomy, slug: "tied-first")
      tied_second_taxonomy = create(:taxonomy, slug: "tied-second")
      create_list(:product, 3, user: seller, taxonomy: top_taxonomy)
      create_list(:product, 2, user: seller, taxonomy: second_taxonomy)
      create(:product, user: seller, taxonomy: tied_first_taxonomy)
      create(:product, user: seller, taxonomy: tied_second_taxonomy)
      scheduled_payout = create(:scheduled_payout, user: seller)

      enrichment = described_class.new([scheduled_payout]).call.fetch(seller.id)

      expected_categories = [
        { slug: "top", product_count: 3 },
        { slug: "second", product_count: 2 },
        { slug: "tied-first", product_count: 1 }
      ]
      expect(enrichment[:top_categories]).to eq(expected_categories)
    end

    it "excludes products without taxonomies from top categories" do
      seller = create(:compliant_user)
      create(:product, user: seller, taxonomy: nil)
      scheduled_payout = create(:scheduled_payout, user: seller)

      enrichment = described_class.new([scheduled_payout]).call.fetch(seller.id)

      expect(enrichment[:top_categories]).to eq([])
    end

    it "returns risk state from the shared presenter" do
      users = [
        create(:compliant_user),
        create(:user, user_risk_state: "suspended_for_fraud"),
        create(:user, user_risk_state: "flagged_for_fraud")
      ]
      scheduled_payouts = users.map { create(:scheduled_payout, user: _1) }

      enrichment_by_user_id = described_class.new(scheduled_payouts).call

      users.each do |user|
        expect(enrichment_by_user_id[user.id][:risk_state]).to eq(Admin::UserRiskStatePresenter.new(user).props)
      end
    end

    it "uses a bounded number of queries for distinct users" do
      taxonomy = create(:taxonomy)
      users = 3.times.map do
        create(:compliant_user).tap do |seller|
          create(:product, user: seller, taxonomy:)
          create(:direct_affiliate, seller:)
          create(:balance, user: seller, merchant_account:, amount_cents: 1_00)
          create(:comment, commentable: seller, comment_type: Comment::COMMENT_TYPE_COMPLIANT)
        end
      end
      scheduled_payouts = users.map { create(:scheduled_payout, user: _1) }

      queries = sql_queries_for { described_class.new(scheduled_payouts).call }

      expect(queries.count).to be <= 6
    end
  end

  def sql_queries_for(&block)
    queries = []
    counter = lambda do |*, payload|
      next if payload[:cached] || payload[:name].in?(["SCHEMA", "TRANSACTION"])

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    queries
  end
end
