# frozen_string_literal: true

require "spec_helper"

RSpec.describe Purchase::Blockable do
  describe "card-testing velocity counting (gumroad-private#1701)" do
    let(:guid) { SecureRandom.uuid }
    let(:email) { "buyer-#{SecureRandom.hex(4)}@example.com" }
    let(:ip) { "203.0.113.44" }

    # Card declines land in stripe_error_code and leave error_code NULL, which is the row shape
    # production actually writes (see Purchase#handle_charge_processor_card_error). Setting
    # error_code instead would test a row that never exists and hide a wrong-column filter.
    def declined(code, fingerprint:, processor: "stripe")
      create(:failed_purchase, email:, browser_guid: guid, ip_address: ip,
                               charge_processor_id: processor,
                               stripe_fingerprint: fingerprint,
                               stripe_error_code: code)
    end

    def outage(code, fingerprint:, processor: "stripe")
      create(:failed_purchase, email:, browser_guid: guid, ip_address: ip,
                               charge_processor_id: processor,
                               stripe_fingerprint: fingerprint,
                               error_code: code)
    end

    def live_attempt(fingerprint: "fp-live-#{SecureRandom.hex(3)}", processor: "stripe")
      create(:failed_purchase, email:, browser_guid: guid, ip_address: ip,
                               charge_processor_id: processor, stripe_fingerprint: fingerprint)
    end

    context "when four distinct cards are declined for fraud" do
      it "still blocks the buyer" do
        4.times { |i| declined(PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: "fraud#{i}") }

        live_attempt.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_present
      end

      it "still blocks the browser guid" do
        4.times { |i| declined(PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: "guidfraud#{i}") }

        live_attempt.send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_present
      end

      it "still blocks the ip address" do
        4.times { |i| declined(PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: "ipfraud#{i}") }

        live_attempt.send(:block_ip_address_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: ip)).to be_present
      end
    end

    context "when the declines describe the buyer's balance" do
      it "does not block on insufficient funds" do
        4.times { |i| declined(PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS, fingerprint: "nsf#{i}") }

        live_attempt.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_nil
      end

      it "does not block on transaction_not_allowed" do
        4.times { |i| declined("card_declined_transaction_not_allowed", fingerprint: "tna#{i}") }

        live_attempt.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_nil
      end

      it "still blocks on the issuer's catch-all decline" do
        4.times { |i| declined("card_declined_generic_decline", fingerprint: "gen#{i}") }

        live_attempt.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_present
      end
    end

    context "when the failures are our own outage codes" do
      it "does not block the buyer" do
        4.times { |i| outage(PurchaseErrorCode::STRIPE_UNAVAILABLE, fingerprint: "out#{i}") }

        live_attempt.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_nil
      end

      it "does not write an IP block during a processor incident" do
        4.times { |i| outage(PurchaseErrorCode::STRIPE_UNAVAILABLE, fingerprint: "outip#{i}") }

        live_attempt.send(:block_ip_address_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: ip)).to be_nil
      end
    end

    context "with PayPal per-transaction tokens" do
      it "does not treat one wallet's retries as four cards" do
        %w[B-4RX09118X48790402 B-1E323802CG6792744 B-9KL22119Y11002931 B-7PQ55410Z22114882]
          .each { |token| declined(PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: token, processor: "paypal") }

        live_attempt(processor: "paypal", fingerprint: "B-live").send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_nil
      end

      it "still blocks somebody cycling four different PayPal accounts" do
        4.times do |i|
          create(:failed_purchase, email: "payer#{i}-#{SecureRandom.hex(3)}@example.com",
                                   browser_guid: guid, ip_address: ip,
                                   charge_processor_id: "paypal",
                                   stripe_fingerprint: "B-#{SecureRandom.hex(8)}",
                                   stripe_error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT)
        end

        live_attempt(processor: "paypal", fingerprint: "B-live2").send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_present
      end
    end
  end
end
