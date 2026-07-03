# frozen_string_literal: true

require "spec_helper"

describe UploadUsStatesSalesTaxToTaxjarJob do
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
  end

  it "is configured with retry: 5" do
    expect(described_class.sidekiq_options["retry"]).to eq(5)
  end

  it "does nothing when the Rails environment is not production" do
    allow(Rails.env).to receive(:production?).and_return(false)
    expect_any_instance_of(TaxjarApi).not_to receive(:create_order_transaction)

    described_class.new.perform("2022-08-10")
  end

  describe "sidekiq_retries_exhausted" do
    it "emails payments notification with the failure context" do
      job = { "args" => ["2026-06-15"] }
      exception = HTTP::ConnectionError.new("failed to connect: getaddrinfo")
      mailer = double("mailer")

      expect(AccountingMailer).to receive(:us_states_sales_tax_taxjar_upload_failed)
        .with("2026-06-15", "HTTP::ConnectionError", "failed to connect: getaddrinfo")
        .and_return(mailer)
      expect(mailer).to receive(:deliver_later)

      described_class.sidekiq_retries_exhausted_block.call(job, exception)
    end

    it "falls back to yesterday's date when the scheduler fired the job with no args" do
      job = { "args" => [] }
      exception = HTTP::ConnectionError.new("failed to connect: getaddrinfo")
      mailer = double("mailer")

      expect(AccountingMailer).to receive(:us_states_sales_tax_taxjar_upload_failed)
        .with(Date.yesterday.iso8601, "HTTP::ConnectionError", "failed to connect: getaddrinfo")
        .and_return(mailer)
      expect(mailer).to receive(:deliver_later)

      described_class.sidekiq_retries_exhausted_block.call(job, exception)
    end
  end

  describe "uploading a day's orders", :vcr do
    before do
      travel_to(Time.find_zone("UTC").local(2022, 8, 10)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        @purchase_wa = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "98121") # King County, Washington
        @purchase_wi = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "United States", zip_code: "53703") # Madison, Wisconsin

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "uploads the given day's taxable US-state order transactions to TaxJar" do
      uploaded_transaction_ids = []
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
        uploaded_transaction_ids << kwargs[:transaction_id]
        {}
      end

      described_class.new.perform("2022-08-10")

      expect(uploaded_transaction_ids).to match_array([@purchase_wa.external_id, @purchase_wi.external_id])
    end

    it "does not upload orders created on a different day" do
      expect_any_instance_of(TaxjarApi).not_to receive(:create_order_transaction)

      described_class.new.perform("2022-08-11")
    end

    it "retries and completes when TaxJar raises a transient connection error" do
      raised = false
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **_kwargs|
        unless raised
          raised = true
          raise HTTP::ConnectionError, "failed to connect: Connection reset by peer - SSL_connect"
        end
        {}
      end
      allow_any_instance_of(UsStateSalesTaxUploader).to receive(:sleep)

      expect { described_class.new.perform("2022-08-10") }.not_to raise_error
    end

    it "defaults to uploading yesterday's orders" do
      travel_to(Time.find_zone("UTC").local(2022, 8, 11, 3)) do
        uploaded_transaction_ids = []
        allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
          uploaded_transaction_ids << kwargs[:transaction_id]
          {}
        end

        described_class.new.perform

        expect(uploaded_transaction_ids).to match_array([@purchase_wa.external_id, @purchase_wi.external_id])
      end
    end
  end
end
