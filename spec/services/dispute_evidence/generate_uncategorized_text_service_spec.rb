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
  end
end
