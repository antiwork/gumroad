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

  describe "uploading a day's refunds (post-cutover)" do
    before do
      travel_to(Time.find_zone("UTC").local(2026, 8, 10)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")
        @purchase_wa = create(:purchase, link: product, country: "United States", zip_code: "98121") # King County, Washington
      end

      travel_to(Time.find_zone("UTC").local(2026, 8, 20, 12)) do
        @refund = create(:refund, purchase: @purchase_wa, amount_cents: @purchase_wa.price_cents)
        @purchase_wa.update!(stripe_refunded: true)
      end
    end

    it "does not push refund transactions for pre-cutover days" do
      travel_to(Time.find_zone("UTC").local(2022, 8, 10)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")
        pre_cutover_purchase = create(:purchase, link: product, country: "United States", zip_code: "98121")
        create(:refund, purchase: pre_cutover_purchase, amount_cents: 100_00)
      end
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction).and_return({})
      expect_any_instance_of(TaxjarApi).not_to receive(:create_refund_transaction)

      described_class.new.perform("2022-08-10")
    end

    it "pushes a post-cutover refund against a pre-cutover purchase, and nets only pre-cutover refunds into the order" do
      cutover = UsStateSalesTaxUploader::REFUND_REPORTING_CUTOVER
      purchase = nil
      travel_to((cutover - 30).to_time(:utc).change(hour: 12)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")
        purchase = create(:purchase, link: product, country: "United States", zip_code: "98121")
      end

      # Netted era: this refund was (or would have been) netted into the order upload.
      pre_cutover_refund_day = cutover - 10
      travel_to(pre_cutover_refund_day.to_time(:utc).change(hour: 12)) do
        create(:refund, purchase:, amount_cents: 20_00)
      end

      # Reported era: this refund must be pushed as its own refund transaction.
      post_cutover_refund_day = cutover + 5
      post_cutover_refund = travel_to(post_cutover_refund_day.to_time(:utc).change(hour: 12)) do
        create(:refund, purchase:, amount_cents: 30_00)
      end

      refund_ids = []
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction) do |_instance, **kwargs|
        refund_ids << kwargs[:transaction_id]
        {}
      end
      described_class.new.perform(pre_cutover_refund_day.iso8601)
      expect(refund_ids).to be_empty

      described_class.new.perform(post_cutover_refund_day.iso8601)
      expect(refund_ids).to eq(["#{post_cutover_refund.external_id}-refund"])

      # A re-push of the purchase's own day must net ONLY the pre-cutover refund (100 - 20),
      # never the post-cutover one — that one is relieved by its refund transaction above.
      order_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
        order_kwargs = kwargs
        {}
      end
      described_class.new.perform((cutover - 30).iso8601)
      expect(order_kwargs[:amount_dollars]).to eq(80.0)
    end

    it "pushes a refund created on the day as a TaxJar refund transaction dated by the refund date" do
      refund_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction) do |_instance, **kwargs|
        refund_kwargs = kwargs
        {}
      end
      expect_any_instance_of(TaxjarApi).not_to receive(:create_order_transaction)

      described_class.new.perform("2026-08-20")

      # The "-refund" suffix keeps refund transaction ids out of the order-id namespace —
      # obfuscated ids derive from numeric row ids, so a bare refund external id could
      # collide with a purchase's and be silently skipped as "already created" in TaxJar.
      expect(refund_kwargs[:transaction_id]).to eq("#{@refund.external_id}-refund")
      expect(refund_kwargs[:transaction_reference_id]).to eq(@purchase_wa.external_id)
      expect(refund_kwargs[:transaction_date]).to eq(@refund.created_at.iso8601)
      expect(refund_kwargs[:amount_dollars]).to eq(@refund.amount_cents / 100.0)
      expect(refund_kwargs[:sales_tax_dollars]).to eq(@refund.gumroad_tax_cents.to_i / 100.0)
    end

    it "does not push a refund on a day the refund was not created" do
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction).and_return({})
      expect_any_instance_of(TaxjarApi).not_to receive(:create_refund_transaction)

      described_class.new.perform("2026-08-21")
    end

    it "does not push refunds with a terminal-failure status" do
      @refund.update!(status: "failed")
      expect_any_instance_of(TaxjarApi).not_to receive(:create_refund_transaction)

      described_class.new.perform("2026-08-20")
    end

    it "pushes a cutover-day refund of an older pre-cutover purchase" do
      # The purchase's netted order upload ran before the cutover, so this refund can't have
      # been netted into it and must be reported as a refund transaction — dropping it would
      # leave TaxJar overstating the period's tax.
      cutover = UsStateSalesTaxUploader::REFUND_REPORTING_CUTOVER
      travel_to((cutover - 10).to_time(:utc).change(hour: 12)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")
        @old_purchase = create(:purchase, link: product, country: "United States", zip_code: "98121")
      end
      old_refund = travel_to(cutover.to_time(:utc).change(hour: 12)) do
        create(:refund, purchase: @old_purchase, amount_cents: 50_00)
      end

      refund_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction) do |_instance, **kwargs|
        refund_kwargs = kwargs
        {}
      end

      described_class.new.perform(cutover.iso8601)

      expect(refund_kwargs[:transaction_id]).to eq("#{old_refund.external_id}-refund")
      expect(refund_kwargs[:transaction_reference_id]).to eq(@old_purchase.external_id)
    end

    it "pushes a cutover-day refund of a purchase created the day before the cutover" do
      # The purchase's netted order upload runs early on the cutover morning, but by then the
      # new code is live (deploy dependency on REFUND_REPORTING_CUTOVER) and nets only
      # pre-cutover refunds — so this cutover-day refund was never netted in and must be
      # reported as its own refund transaction.
      cutover = UsStateSalesTaxUploader::REFUND_REPORTING_CUTOVER
      travel_to((cutover - 1).to_time(:utc).change(hour: 20)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")
        @eve_purchase = create(:purchase, link: product, country: "United States", zip_code: "98121")
      end
      eve_refund = travel_to(cutover.to_time(:utc).change(hour: 12)) do
        create(:refund, purchase: @eve_purchase, amount_cents: 50_00)
      end

      refund_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction) do |_instance, **kwargs|
        refund_kwargs = kwargs
        {}
      end

      described_class.new.perform(cutover.iso8601)

      expect(refund_kwargs[:transaction_id]).to eq("#{eve_refund.external_id}-refund")
      expect(refund_kwargs[:transaction_reference_id]).to eq(@eve_purchase.external_id)

      # And the purchase's own (netted) order upload — which runs on the cutover morning —
      # must net only pre-cutover refunds, i.e. report the full gross here, so the refund
      # transaction above is the only thing relieving that tax.
      order_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
        order_kwargs = kwargs
        {}
      end
      described_class.new.perform((cutover - 1).iso8601)
      expect(order_kwargs[:amount_dollars]).to eq(100.0)
    end

    it "uploads a fully refunded purchase's order at its gross amounts on the purchase day" do
      order_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
        order_kwargs = kwargs
        {}
      end
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction).and_return({})

      described_class.new.perform("2026-08-10")

      # The order must be reported gross even though the purchase is fully refunded by the
      # time of this (re-)push: its refund is reported separately in the refund's own period,
      # so netting it into the order would relieve the tax twice.
      expect(order_kwargs[:transaction_id]).to eq(@purchase_wa.external_id)
      expect(order_kwargs[:sales_tax_dollars]).to eq(@purchase_wa.gumroad_tax_cents / 100.0)
      expect(order_kwargs[:amount_dollars]).to eq((@purchase_wa.price_cents + @purchase_wa.shipping_cents) / 100.0)
    end
  end

  describe "uploading a day's chargebacks (post-cutover)" do
    let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER }

    before do
      travel_to((cutover - 30).to_time(:utc).change(hour: 12)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")
        @purchase = create(:purchase, link: product, country: "United States", zip_code: "98121") # Washington
      end
    end

    it "pushes a chargeback as a refund transaction dated by the dispute event date" do
      event_day = cutover + 5
      @purchase.update!(chargeback_date: event_day.to_time(:utc).change(hour: 12))
      # chargeback_date mirrors the dispute's event_created_at in production; the tax-period
      # scope resolves the window through disputes, so the purchase needs its Dispute row.
      create(:dispute, purchase: @purchase, event_created_at: @purchase.chargeback_date)

      refund_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction) do |_instance, **kwargs|
        refund_kwargs = kwargs
        {}
      end

      described_class.new.perform(event_day.iso8601)

      expect(refund_kwargs[:transaction_id]).to eq("#{@purchase.external_id}-chargeback")
      expect(refund_kwargs[:transaction_reference_id]).to eq(@purchase.external_id)
      expect(refund_kwargs[:transaction_date]).to eq(@purchase.chargeback_date.iso8601)
      expect(refund_kwargs[:amount_dollars]).to eq(@purchase.price_cents / 100.0)
      expect(refund_kwargs[:sales_tax_dollars]).to eq(@purchase.gumroad_tax_cents / 100.0)

      # The charged-back purchase's order upload keeps reporting its sale on the purchase
      # day — the chargeback transaction above is what backs it out, so dropping the order
      # (the legacy behavior) would subtract the money twice.
      order_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
        order_kwargs = kwargs
        {}
      end
      described_class.new.perform((cutover - 30).iso8601)
      expect(order_kwargs[:transaction_id]).to eq(@purchase.external_id)
    end

    it "nets the purchase's refunds out of the chargeback amounts" do
      travel_to((cutover - 20).to_time(:utc).change(hour: 12)) do
        create(:refund, purchase: @purchase, amount_cents: 40_00)
      end
      event_day = cutover + 5
      @purchase.update!(chargeback_date: event_day.to_time(:utc).change(hour: 12))
      create(:dispute, purchase: @purchase, event_created_at: @purchase.chargeback_date)

      refund_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction) do |_instance, **kwargs|
        refund_kwargs = kwargs
        {}
      end

      described_class.new.perform(event_day.iso8601)

      # The refund already relieved 40.00 through its own path; the dispute claws back only
      # the remaining 60.00.
      expect(refund_kwargs[:transaction_id]).to eq("#{@purchase.external_id}-chargeback")
      expect(refund_kwargs[:amount_dollars]).to eq(60.0)
    end

    it "does not push legs for pre-cutover chargebacks" do
      event_day = cutover - 5
      @purchase.update!(chargeback_date: event_day.to_time(:utc).change(hour: 12))
      # A real Dispute row exists, but its event date is before the cutover, so the leg is
      # still skipped — the exclusion comes from the cutover gate, not a missing dispute.
      create(:dispute, purchase: @purchase, event_created_at: @purchase.chargeback_date)
      expect_any_instance_of(TaxjarApi).not_to receive(:create_refund_transaction)
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction).and_return({})

      described_class.new.perform(event_day.iso8601)
    end

    it "does not push legs for a reversed chargeback with no dispute row dating the win" do
      event_day = cutover + 5
      @purchase.update!(chargeback_date: event_day.to_time(:utc).change(hour: 12), chargeback_reversed: true)
      # The formalization dispute exists (event date in the window) but records no won_at, so
      # neither the debit leg (reversed with no win) nor the re-add leg (no reversal date) fires.
      create(:dispute, purchase: @purchase, event_created_at: @purchase.chargeback_date)
      expect_any_instance_of(TaxjarApi).not_to receive(:create_refund_transaction)
      expect_any_instance_of(TaxjarApi).not_to receive(:create_order_transaction)

      described_class.new.perform(event_day.iso8601)
    end

    it "pushes a won dispute as a re-add order transaction dated by the dispute's won_at" do
      event_day = cutover + 5
      won_day = cutover + 40
      won_at = won_day.to_time(:utc).change(hour: 12)
      @purchase.update!(chargeback_date: event_day.to_time(:utc).change(hour: 12), chargeback_reversed: true)
      create(:dispute, purchase: @purchase, state: "won", won_at:)

      order_kwargs = nil
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
        order_kwargs = kwargs
        {}
      end
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction).and_return({})

      described_class.new.perform(won_day.iso8601)

      expect(order_kwargs[:transaction_id]).to eq("#{@purchase.external_id}-chargeback-reversal")
      expect(order_kwargs[:transaction_date]).to eq(won_at.iso8601)
      expect(order_kwargs[:amount_dollars]).to eq(@purchase.price_cents / 100.0)
      expect(order_kwargs[:sales_tax_dollars]).to eq(@purchase.gumroad_tax_cents / 100.0)
    end

    it "dates the re-add by the canonical reversal date when several dispute rows exist" do
      # Two dispute rows with different won_at values. The canonical reporting date is the
      # latest won_at (chargeback_reversal_reporting_date), so the run for the EARLIER row's
      # day must emit nothing — otherwise that day's push would carry a transaction_date
      # outside its own filing window — and the canonical day's run emits the one leg.
      event_day = cutover + 5
      early_won_day = cutover + 40
      late_won_day = cutover + 41
      early_won_at = early_won_day.to_time(:utc).change(hour: 12)
      late_won_at = late_won_day.to_time(:utc).change(hour: 10)
      @purchase.update!(chargeback_date: event_day.to_time(:utc).change(hour: 12), chargeback_reversed: true)
      create(:dispute, purchase: @purchase, state: "won", won_at: early_won_at)
      create(:dispute, purchase: @purchase, state: "won", won_at: late_won_at)

      order_calls = []
      allow_any_instance_of(TaxjarApi).to receive(:create_order_transaction) do |_instance, **kwargs|
        order_calls << kwargs
        {}
      end
      allow_any_instance_of(TaxjarApi).to receive(:create_refund_transaction).and_return({})

      described_class.new.perform(early_won_day.iso8601)
      expect(order_calls).to be_empty

      described_class.new.perform(late_won_day.iso8601)
      expect(order_calls.size).to eq(1)
      expect(order_calls.first[:transaction_id]).to eq("#{@purchase.external_id}-chargeback-reversal")
      expect(order_calls.first[:transaction_date]).to eq(late_won_at.iso8601)
    end
  end
end
