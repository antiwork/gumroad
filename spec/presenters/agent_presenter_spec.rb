# frozen_string_literal: true

require "spec_helper"

describe AgentPresenter do
  let(:seller) { create(:named_seller) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  describe "#index_props" do
    it "reports an eligible seller as eligible" do
      allow(seller).to receive(:eligible_for_store_agent?).and_return(true)

      expect(described_class.new(pundit_user:).index_props[:eligible]).to eq(true)
    end

    it "reports a seller under the earned-access bar as ineligible" do
      allow(seller).to receive(:eligible_for_store_agent?).and_return(false)

      expect(described_class.new(pundit_user:).index_props[:eligible]).to eq(false)
    end

    it "always ships the locked copy so the page can explain the bar without a second request" do
      allow(seller).to receive(:eligible_for_store_agent?).and_return(true)
      props = described_class.new(pundit_user:).index_props

      expect(props[:locked_heading]).to eq(described_class::LOCKED_HEADING)
      expect(props[:locked_explanation]).to eq(described_class::LOCKED_EXPLANATION)
    end
  end

  describe "LOCKED_EXPLANATION" do
    # A property, not the literal: the copy has to state the actual bar (a hardcoded "$100" would
    # silently drift if MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT ever moves), and it must not tell the
    # seller to write in — the whole defect was sellers having no way to learn this but a ticket.
    it "names the sales threshold the gate actually uses" do
      formatted = MoneyFormatter.format(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT, :usd, no_cents_if_whole: true, symbol: true)

      expect(described_class::LOCKED_EXPLANATION).to include(formatted)
    end

    it "says the access returns on its own rather than asking the seller to contact support" do
      expect(described_class::LOCKED_EXPLANATION).to match(/on its own|automatically/)
      expect(described_class::LOCKED_EXPLANATION).to_not match(/contact (us|support)|email us|get in touch/i)
    end
  end

  describe "LOCKED_NAV_BADGE" do
    # eligible_for_store_agent? also requires a completed payout, so a seller can be well past
    # $100 in sales and still ineligible — naming the sales figure here would read as wrong for
    # that seller. Only LOCKED_EXPLANATION, which states both conditions, may name the amount.
    it "does not name the sales figure, unlike LOCKED_EXPLANATION" do
      formatted = MoneyFormatter.format(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT, :usd, no_cents_if_whole: true, symbol: true)

      expect(described_class::LOCKED_NAV_BADGE).to_not include(formatted)
    end
  end
end
