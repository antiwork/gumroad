# frozen_string_literal: true

require "spec_helper"

describe ProductPresenter::Card do
  describe "#for_web seller-level lookups across one request (gp#4844)" do
    let(:seller) { create(:user) }
    let(:products) { create_list(:product, 5, user: seller) }
    let(:request) { ActionDispatch::TestRequest.create }

    it "checks the seller's buyer-local-currency opt-in once per request, not once per card" do
      expect(Feature).to receive(:active?).with(:buyer_local_currency, seller).once.and_call_original

      cards = products.map { |product| described_class.new(product:).for_web(request:) }

      expect(cards.map { _1[:id] }).to match_array(products.map(&:external_id))
    end

    it "still checks the opt-in on every call when there is no request to remember it on" do
      product = products.first
      allow(request).to receive(:respond_to?).and_call_original
      allow(request).to receive(:respond_to?).with(:env).and_return(false)
      expect(Feature).to receive(:active?).with(:buyer_local_currency, seller).twice.and_call_original

      2.times { described_class.new(product:).for_web(request:) }
    end
  end
end
