# frozen_string_literal: true

require "spec_helper"

RSpec.describe Purchase::Blockable do
  describe "card-testing velocity counting (gumroad-private#1701)" do
    let(:guid) { SecureRandom.uuid }
    let(:email) { "buyer-#{SecureRandom.hex(4)}@example.com" }
    let(:ip) { "203.0.113.44" }

    def failed_attempt(error_code:, fingerprint:, processor: "stripe", guid_override: nil)
      create(:failed_purchase,
             email:,
             browser_guid: guid_override || guid,
             ip_address: ip,
             charge_processor_id: processor,
             stripe_fingerprint: fingerprint,
             error_code:)
    end

    # The trigger under test fires at MAX_NUMBER_OF_FAILED_FINGERPRINTS (4) distinct fingerprints.
    def trip_with(error_code:, processor: "stripe")
      4.times { |i| failed_attempt(error_code:, fingerprint: "fp#{i}#{SecureRandom.hex(3)}", processor:) }
      purchase = build(:purchase, email:, browser_guid: guid, ip_address: ip,
                                  stripe_fingerprint: "fp-live-#{SecureRandom.hex(3)}")
      purchase.send(:block_buyer_based_on_recent_failures!)
      purchase
    end

    context "when the failures are ordinary issuer declines" do
      it "does not block on insufficient funds" do
        trip_with(error_code: PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_nil
        expect(PlatformBlock.active.find_by(object_value: guid)).to be_nil
      end

      it "does not block on transaction_not_allowed" do
        trip_with(error_code: "card_declined_transaction_not_allowed")

        expect(PlatformBlock.active.find_by(object_value: email)).to be_nil
      end
    end

    context "when the failures are our own outage codes" do
      it "does not block on stripe_unavailable" do
        trip_with(error_code: PurchaseErrorCode::STRIPE_UNAVAILABLE)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_nil
      end

      it "does not write an IP block during a processor incident" do
        4.times { |i| failed_attempt(error_code: PurchaseErrorCode::STRIPE_UNAVAILABLE, fingerprint: "ip-fp#{i}") }
        purchase = build(:purchase, email:, browser_guid: guid, ip_address: ip,
                                    stripe_fingerprint: "fp-live")
        purchase.send(:block_ip_address_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: ip)).to be_nil
      end
    end

    context "when the failures are genuine fraud declines" do
      it "still blocks the buyer" do
        4.times { |i| failed_attempt(error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: "fraud-fp#{i}") }
        purchase = create(:failed_purchase, email:, browser_guid: guid, ip_address: ip,
                                            stripe_fingerprint: "fp-live-fraud",
                                            error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT)
        purchase.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_present
      end
    end

    context "when the distinct fingerprints are PayPal per-transaction tokens" do
      it "does not treat one wallet as four cards" do
        %w[B-4RX09118X48790402 B-1E323802CG6792744 B-9KL22119Y11002931 B-7PQ55410Z22114882]
          .each { |token| failed_attempt(error_code: PurchaseErrorCode::PAYPAL_UNAVAILABLE, fingerprint: token, processor: "paypal") }

        purchase = build(:purchase, email:, browser_guid: guid, ip_address: ip,
                                    stripe_fingerprint: "B-live-token")
        purchase.send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_nil
      end
    end
  end
end
