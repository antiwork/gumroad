# frozen_string_literal: true

require "spec_helper"

describe AdminMailer do
  describe "#chargeback_notify" do
    context "for a dispute on Purchase" do
      let!(:purchase) { create(:purchase) }
      let!(:dispute) { create(:dispute_formalized, purchase:) }
      let!(:mail) { described_class.chargeback_notify(dispute.id) }

      it "emails payments" do
        expect(mail.to).to eq [ApplicationMailer::RISK_EMAIL]
      end

      it "has the id of the seller" do
        expect(mail.body).to include(dispute.disputable.seller.id)
      end

      it "has the details of the purchase" do
        expect(mail.subject).to eq "[test] Chargeback for #{purchase.formatted_disputed_amount} on #{purchase.link.name}"
        expect(mail.body.encoded).to include purchase.link.name
        expect(mail.body.encoded).to include purchase.formatted_disputed_amount
      end
    end

    context "for a dispute on Charge", :vcr do
      let!(:charge) do
        charge = create(:charge, seller: create(:user), amount_cents: 15_00)
        charge.purchases << create(:purchase, link: create(:product, user: charge.seller), total_transaction_cents: 2_50)
        charge.purchases << create(:purchase, link: create(:product, user: charge.seller), total_transaction_cents: 5_00)
        charge.purchases << create(:purchase, link: create(:product, user: charge.seller), total_transaction_cents: 7_50)
        charge
      end
      let!(:dispute) { create(:dispute_formalized_on_charge, purchase: nil, charge:) }
      let!(:mail) { described_class.chargeback_notify(dispute.id) }

      it "emails payments" do
        expect(mail.to).to eq [ApplicationMailer::RISK_EMAIL]
      end

      it "has the id of the seller" do
        expect(mail.body).to include(dispute.disputable.seller.id)
      end

      it "has the details of all included purchases" do
        selected_purchase = charge.purchase_for_dispute_evidence
        expect(mail.subject).to eq "[test] Chargeback for #{charge.formatted_disputed_amount} on #{selected_purchase.link.name} and 2 other products"
        charge.disputed_purchases.each do |purchase|
          expect(mail.body.encoded).to include purchase.external_id
          expect(mail.body.encoded).to include purchase.link.name
        end
      end
    end
  end

  describe "#low_balance_notify", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    before do
      @user = create(:user, name: "Test Creator", unpaid_balance_cents: -600_00)

      @last_refunded_purchase = create(:purchase)
      @mail = AdminMailer.low_balance_notify(@user.id, @last_refunded_purchase.id)
    end

    it "has 'to' field set to risk@gumroad.com" do
      expect(@mail.to).to eq([ApplicationMailer::RISK_EMAIL])
    end

    it "has the correct subject" do
      expect(@mail.subject).to eq "[test] Low balance for creator - Test Creator ($-600)"
    end

    it "includes user balance in mail body" do
      expect(@mail.body).to include("Balance: $-600")
    end

    it "includes admin purchase link" do
      expect(@mail.body).to include(admin_purchase_url(@last_refunded_purchase))
    end

    it "includes admin product link" do
      expect(@mail.body).to include(admin_product_url(@last_refunded_purchase.link.unique_permalink))
    end
  end

  describe "#inverted_sales_to_views_notify" do
    let(:product) { create(:product, name: "The Freebie") }
    let(:mail) { described_class.inverted_sales_to_views_notify(product.id, 4_200, 37) }

    it "goes to risk" do
      expect(mail.to).to eq([ApplicationMailer::RISK_EMAIL])
    end

    it "puts the product and both counts in the subject" do
      expect(mail.subject).to eq "[test] Auto-flagged for inverted sales-to-views - The Freebie (4,200 sales / 37 views)"
    end

    it "links the product and says the product is already down" do
      expect(mail.body.encoded).to include(admin_product_url(product.unique_permalink))
      expect(mail.body.encoded).to include("4,200")
      expect(mail.body.encoded).to include("37")
      expect(mail.body.encoded).to include("already been unpublished")
    end

    it "includes the seller's details" do
      expect(mail.body).to include(product.user.id)
    end
  end
end
