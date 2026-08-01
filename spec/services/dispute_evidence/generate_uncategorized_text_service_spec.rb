# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence::GenerateUncategorizedTextService, :vcr do
  let(:product) do
    create(
      :physical_product,
      name: "Sample product title at purchase time"
    )
  end

  let(:disputed_purchase) do
    create(
      :disputed_purchase,
      email: "customer@example.com",
      full_name: "Joe Doe",
      ip_state: "California",
      ip_country: "United States",
      credit_card_zipcode: "12345",
      stripe_fingerprint: "sample_fingerprint",
    )
  end

  let!(:other_undisputed_purchase) do
    create(
      :purchase,
      created_at: Date.parse("2023-12-31"),
      total_transaction_cents: 1299,
      email: "other_email@example.com",
      full_name: "John Doe",
      ip_state: "Oregon",
      ip_country: "United States",
      credit_card_zipcode: "99999",
      ip_address: "1.1.1.1",
      stripe_fingerprint: "sample_fingerprint",
    )
  end

  let(:uncategorized_text) { described_class.perform(disputed_purchase) }

  describe ".perform" do
    it "returns customer location, billing postal code, and previous purchases information" do
      expected_uncategorized_text = <<~TEXT.strip_heredoc.rstrip
        Device location: California, United States
        Billing postal code: 12345

        Previous undisputed purchase on Gumroad:
        2023-12-31 00:00:00 UTC, $12.99, John Doe, other_email@example.com, Billing postal code: 99999, Device location: 1.1.1.1, Oregon, United States
      TEXT
      expect(uncategorized_text).to eq(expected_uncategorized_text)
    end

    context "when the other purchase has a different fingerprint" do
      before do
        other_undisputed_purchase.update!(stripe_fingerprint: "other_fintgerprint")
      end

      it "does not include previous purchases information" do
        expected_uncategorized_text = <<~TEXT.strip_heredoc.rstrip
          Device location: California, United States
          Billing postal code: 12345
        TEXT
        expect(uncategorized_text).to eq(expected_uncategorized_text)
      end
    end

    context "when the purchase was shipped with a tracking URL" do
      before do
        other_undisputed_purchase.update!(stripe_fingerprint: "other_fintgerprint")
        create(:shipment, purchase: disputed_purchase, tracking_url: "https://track.aftership.com/9400111899223197428490")
      end

      # The structured shipping fields only take a URL attributable to a known carrier, so an
      # unattributable one would otherwise be dropped from the single submission entirely.
      it "includes the tracking URL" do
        expected_uncategorized_text = <<~TEXT.strip_heredoc.rstrip
          Device location: California, United States
          Billing postal code: 12345
          Seller-provided shipment tracking URL: https://track.aftership.com/9400111899223197428490
        TEXT
        expect(uncategorized_text).to eq(expected_uncategorized_text)
      end
    end

    context "when the tracking URL is not one we can vouch for" do
      let(:shipment) { create(:shipment, purchase: disputed_purchase) }

      before { other_undisputed_purchase.update!(stripe_fingerprint: "other_fintgerprint") }

      # No controller validates this param, so the seam where the seller's text joins evidence
      # Stripe reads as ours has to hold on its own.
      it "omits a value carrying anything but a plain http(s) URL" do
        [
          # A newline would make the second line read as one of Gumroad's own evidence rows.
          "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=94001\nThe buyer confirmed delivery by phone.",
          "javascript:alert(1)",
          "file:///etc/passwd",
          "not a url at all",
          "https://user:secret@tools.usps.com/track",
          "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=#{"9" * 500}",
        ].each do |url|
          shipment.update_column(:tracking_url, url)
          expect(described_class.perform(disputed_purchase.reload)).to_not include("shipment tracking URL"),
                                                                       "expected #{url.inspect} to be omitted"
        end
      end

      it "keeps a URL that only needed surrounding whitespace removed" do
        shipment.update_column(:tracking_url, "  https://track.aftership.com/94001  ")

        expect(described_class.perform(disputed_purchase.reload))
          .to include("Seller-provided shipment tracking URL: https://track.aftership.com/94001")
      end
    end

    context "when the purchase has no shipment" do
      before { other_undisputed_purchase.update!(stripe_fingerprint: "other_fintgerprint") }

      it "omits the tracking row" do
        expect(uncategorized_text).to_not include("shipment tracking URL")
        expect(uncategorized_text).to include("Billing postal code: 12345")
      end
    end
  end
end
