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
    def declined(code, fingerprint:, processor: "stripe", created_at: Time.current)
      create(:failed_purchase, email:, browser_guid: guid, ip_address: ip,
                               charge_processor_id: processor,
                               stripe_fingerprint: fingerprint,
                               stripe_error_code: code,
                               created_at:)
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

    context "when the issuer answered about the card" do
      # The attacker picks the amount and the card, so exempting an issuer-answered decline hands
      # them a velocity-free oracle for validating a stolen list.
      it "still blocks on insufficient funds" do
        4.times { |i| declined(PurchaseErrorCode::STRIPE_INSUFFICIENT_FUNDS, fingerprint: "nsf#{i}") }

        live_attempt.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_present
      end

      it "still blocks on transaction_not_allowed" do
        4.times { |i| declined("card_declined_transaction_not_allowed", fingerprint: "tna#{i}") }

        live_attempt.send(:block_buyer_based_on_recent_failures!)

        expect(PlatformBlock.active.find_by(object_value: email)).to be_present
      end

      it "does not block when our own call never reached the processor" do
        4.times { |i| declined("card_declined_processing_error", fingerprint: "pe#{i}") }

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

    context "when a flood of newer retries outnumbers any bounded scan" do
      # Bulk-copies the row: hundreds of factory purchases would dominate the suite's runtime,
      # and the flood only has to exist, not to be individually distinct.
      def flood_with_copies_of(purchase, count:)
        columns = (Purchase.column_names - ["id"]).map { |column| "`#{column}`" }.join(", ")
        count.times do
          ActiveRecord::Base.connection.execute(
            "INSERT INTO purchases (#{columns}) SELECT #{columns} FROM purchases WHERE id = #{purchase.id}"
          )
        end
      end

      # A newest-N row cap taken before deduplication made the count depend on retry order: a
      # tester could hold to three cards, retry them past the cap, and the fourth card fell out
      # of the window before it was ever counted.
      it "still counts a card that only appears past the flood" do
        declined(PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: "older-card", created_at: 2.hours.ago)
        declined(PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: "flood-a", created_at: 1.hour.ago)
        flood_source = declined(PurchaseErrorCode::CARD_DECLINED_FRAUDULENT, fingerprint: "flood-b", created_at: 1.hour.ago)
        flood_with_copies_of(flood_source, count: 201)

        live_attempt.send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_present
      end
    end

    context "with PayPal per-transaction tokens" do
      # card_visual holds the payer email PayPal attested for the order; purchases.email is typed
      # by the buyer at checkout. These specs vary them independently on purpose.
      def paypal_attempt(token:, payer:, checkout_email: email)
        create(:failed_purchase, email: checkout_email, browser_guid: guid, ip_address: ip,
                                 charge_processor_id: "paypal",
                                 stripe_fingerprint: token, card_visual: payer,
                                 stripe_error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT)
      end

      it "does not treat one wallet's retries as four cards" do
        %w[B-4RX09118X48790402 B-1E323802CG6792744 B-9KL22119Y11002931 B-7PQ55410Z22114882]
          .each { |token| paypal_attempt(token:, payer: "wallet@example.com") }

        live_attempt(processor: "paypal", fingerprint: "B-live").send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_nil
      end

      it "blocks four different wallets even when they share one checkout email" do
        4.times do |i|
          paypal_attempt(token: "B-#{SecureRandom.hex(8)}", payer: "stolen#{i}@example.com",
                         checkout_email: email)
        end

        live_attempt(processor: "paypal", fingerprint: "B-live2").send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_present
      end

      it "counts wallets with no attested payer on their own token" do
        4.times { paypal_attempt(token: "B-#{SecureRandom.hex(8)}", payer: nil) }

        live_attempt(processor: "paypal", fingerprint: "B-live3").send(:ban_fraudulent_buyer_browser_guid!)

        expect(PlatformBlock.active.find_by(object_value: guid)).to be_present
      end
    end
  end
end
