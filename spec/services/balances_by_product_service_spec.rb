# frozen_string_literal: true

require "spec_helper"

describe BalancesByProductService do
  include CollabProductHelper

  describe "#process" do
    let(:user) { create(:user) }

    before do
      (0...5).each do |i|
        product = create(:product, user:, name: "product #{i}", purchase_disabled_at: i == 4 ? Time.current : nil)
        (0...10).each do |j|
          purchase = create :purchase, link: product, seller: user, purchase_state: :successful, price_cents: 1000 + 200 * i + 100 * j, tax_cents: 5 * i + 7 * j, created_at: j.days.ago

          if j == 2
            flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 200)
            purchase.refund_purchase!(flow_of_funds, user.id)
          elsif j == 3
            flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, purchase.total_transaction_cents)
            purchase.refund_purchase!(flow_of_funds, user.id)
          elsif j == 4
            purchase.update!(chargeback_date: 4.days.ago)
          end
        end
      end

      @collab_stats = setup_collab_purchases_for(user)

      index_model_records(Purchase)
    end

    it "doesn't error if product is deleted" do
      user.links.first.delete
      balances = described_class.new(user).process
      expect(balances.size).to eq(5)
    end

    it "doesn't list products with no sales" do
      product = create(:product, user:)
      balances = described_class.new(user).process
      product_ids = balances.map { |balance| balance["link_id"] }
      expect(product_ids).not_to eq(product.id)
    end

    it "has expected values" do
      balances = described_class.new(user).process

      expect(balances[0]).to include("name" => "collab product", "gross" => @collab_stats[:gross], "fees" => @collab_stats[:fees], "taxes" => 0, "refunds" => @collab_stats[:refunds], "chargebacks" => @collab_stats[:chargebacks], "net" => @collab_stats[:net])
      expect(balances[1]).to include("name" => "product 4", "gross" => 22500, "fees" => 2955, "taxes" => 423, "refunds" => 2300, "chargebacks" => 2200, "net" => 14622)
      expect(balances[2]).to include("name" => "product 3", "gross" => 20500, "fees" => 2748, "taxes" => 383, "refunds" => 2100, "chargebacks" => 2000, "net" => 13269)
      expect(balances[3]).to include("name" => "product 2", "gross" => 18500, "fees" => 2541, "taxes" => 343, "refunds" => 1900, "chargebacks" => 1800, "net" => 11916)
      expect(balances[4]).to include("name" => "product 1", "gross" => 16500, "fees" => 2332, "taxes" => 304, "refunds" => 1700, "chargebacks" => 1600, "net" => 10564)
      expect(balances[5]).to include("name" => "product 0", "gross" => 14500, "fees" => 2123, "taxes" => 264, "refunds" => 1500, "chargebacks" => 1400, "net" => 9213)
    end
  end
end
