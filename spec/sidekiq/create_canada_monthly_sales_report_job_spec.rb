# frozen_string_literal: true

require "spec_helper"

describe CreateCanadaMonthlySalesReportJob do
  let(:month) { 1 }
  let(:year) { 2015 }

  it "raises an argument error if the year is out of bounds" do
    expect { described_class.new.perform(month, 2013) }.to raise_error(ArgumentError)
  end

  it "raises an agrument error if the month is out of bounds" do
    expect { described_class.new.perform(13, year) }.to raise_error(ArgumentError)
  end

  describe "happy case", :vcr do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/international-sales-reporting-spec-#{SecureRandom.hex(18)}.zip")
    end

    before do
      allow_any_instance_of(Link).to receive(:recommendable?).and_return(true)
      subscription_product = nil
      subscription = nil
      travel_to(Time.zone.local(2014, 12, 1)) do
        subscription_product = create(:subscription_product, price_cents: 100_00)
        subscription = create(:subscription, link_id: subscription_product.id)
        create(:purchase, link: subscription_product, is_original_subscription_purchase: true, subscription:, was_product_recommended: true, country: "Canada", state: nil)
      end
      travel_to(Time.zone.local(2015, 1, 1)) do
        product = create(:product, price_cents: 100_00, native_type: "digital")

        @purchase1 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "Canada", state: "ON", ip_country: "Canada")
        @purchase2 = create(:purchase_in_progress, link: product, was_product_recommended: true, country: "Canada", state: "QC", ip_country: "Canada")
        @purchase3 = create(:purchase_in_progress, link: product, country: "Canada", state: "AB", ip_country: "Canada")
        create(:purchase_in_progress, link: product, country: "Singapore")
        create(:purchase_in_progress, link: product, country: "Canada", state: "saskatoon")
        create(:purchase_in_progress, link: product, country: "Canada", state: "ON", card_country: "US", ip_country: "United States")
        create(:purchase_in_progress, link: subscription_product, subscription:, country: "Canada", state: nil)

        Purchase.in_progress.find_each do |purchase|
          purchase.chargeable = create(:chargeable)
          purchase.process!
          purchase.update_balance_and_mark_successful!
        end
      end
    end

    it "creates a CSV file for all sales into Canada" do
      expect(s3_bucket_double).to receive(:object).ordered.and_return(@s3_object)

      described_class.new.perform(month, year)

      expect(InternalNotificationWorker).to have_enqueued_sidekiq_job("payments", "Canada Sales Reporting", anything, "green", anything)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      expect(actual_payload.length).to eq(4)
      expect(actual_payload[0]).to eq([
                                        "Purchase External ID",
                                        "Purchase Date",
                                        "Member State of Consumption",
                                        "Gumroad Product Type",
                                        "TaxJar Product Tax Code",
                                        "GST Tax Rate",
                                        "PST Tax Rate",
                                        "QST Tax Rate",
                                        "Combined Tax Rate",
                                        "Calculated Tax Amount",
                                        "Tax Collected by Gumroad",
                                        "Price",
                                        "Gumroad Fee",
                                        "Shipping",
                                        "Total",
                                        "Receipt URL",
                                      ])

      expect(@purchase1.purchase_taxjar_info).to be_present
      expect(actual_payload[1]).to eq([
                                        @purchase1.external_id,
                                        "01/01/2015",
                                        "Ontario",
                                        "digital",
                                        "31000",
                                        "0.05",
                                        "0.08",
                                        "0.0",
                                        "0.13",
                                        "13.00",
                                        "13.00",
                                        "100.00",
                                        "30.00",
                                        "0.00",
                                        "113.00",
                                        @purchase1.receipt_url,
                                      ])

      expect(@purchase2.purchase_taxjar_info).to be_present
      expect(actual_payload[2]).to eq([
                                        @purchase2.external_id,
                                        "01/01/2015",
                                        "Quebec",
                                        "digital",
                                        "31000",
                                        "0.05",
                                        "0.0",
                                        "0.09975",
                                        "0.14975",
                                        "14.98",
                                        "14.98",
                                        "100.00",
                                        "30.00",
                                        "0.00",
                                        "114.98",
                                        @purchase2.receipt_url,
                                      ])
    end
  end

  describe "refund period attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/canada-monthly-refund-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }
    let(:report_month_start) { (cutover + 1.month).beginning_of_month }

    before do
      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold (post-cutover) in the month before the reported one, refunded during the reported
      # month: the refund must appear in the reported month as a negative row.
      travel_to(report_month_start - 5.days) do
        @cross_month_purchase = create(:purchase, link: product, price_cents: 100_00, fee_cents: 30_00,
                                                  gumroad_tax_cents: 13_00, total_transaction_cents: 113_00,
                                                  country: "Canada", state: "ON", ip_country: "Canada")
      end

      travel_to(report_month_start + 5.days) do
        @refund = create(:refund, purchase: @cross_month_purchase, amount_cents: 50_00, fee_cents: 15_00,
                                  gumroad_tax_cents: 6_50, total_transaction_cents: 56_50)
        @cross_month_purchase.update!(stripe_partially_refunded: true)
      end
    end

    it "reports the refund as a negative row in the month the refund happened" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(report_month_start.month, report_month_start.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      # Header + the refund row. The purchase itself was sold the month before, so its sale
      # row belongs to that month, not this one.
      expect(actual_payload.length).to eq(2)
      refund_row = actual_payload[1]
      expect(refund_row[0]).to eq(@cross_month_purchase.external_id)
      expect(refund_row[1]).to eq(@refund.created_at.strftime("%m/%d/%Y"))
      expect(refund_row[9]).to eq("-6.50")   # Calculated Tax Amount
      expect(refund_row[10]).to eq("-6.50")  # Tax Collected by Gumroad
      expect(refund_row[11]).to eq("-50.00") # Price
      expect(refund_row[12]).to eq("-15.00") # Gumroad Fee
      expect(refund_row[14]).to eq("-56.50") # Total

      temp_file.close(true)
    end

    it "does not report a refund that leaves the effective scope between the id walk and the batch load" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      # The leg collects the refund's id while it is still effective, then its balance debits are
      # reversed before the batch carrying it is read. The refund leg must not report it: the row
      # is written from the id walk, so the load has to reapply the leg's scope.
      job = described_class.new
      raced = false
      allow(job).to receive(:each_batch) do |scope, &block|
        ids = scope.pluck(:id).sort
        if !raced && scope.klass == Refund && ids.include?(@refund.id)
          raced = true
          @refund.update!(status: "failed")
          @refund.balance_reversed_on_failure = true
          @refund.balance_reversed_on_failure_at = Time.current.utc.iso8601
          @refund.save!
        end
        ids.each_slice(described_class::ROW_BATCH_SIZE, &block)
      end

      job.perform(report_month_start.month, report_month_start.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      # Header only: the purchase's sale belongs to the month before, and the refund is now
      # outside Refund.effective.
      expect(actual_payload.length).to eq(1)

      temp_file.close(true)
    end

    it "does not restate the purchase's own month when re-generated after the refund" do
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      purchase_month = report_month_start - 1.month
      described_class.new.perform(purchase_month.month, purchase_month.year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      actual_payload = CSV.read(temp_file)

      # The sale month regenerates with the purchase at its gross amounts — the later refund
      # belongs to the following month and must not leak backwards.
      expect(actual_payload.length).to eq(2)
      sale_row = actual_payload[1]
      expect(sale_row[0]).to eq(@cross_month_purchase.external_id)
      expect(sale_row[11]).to eq("100.00") # Price, gross

      temp_file.close(true)
    end
  end

  describe "batched leg loading" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    let(:cutover) { Purchase::Reportable::REFUND_REPORTING_CUTOVER }
    let(:report_month_start) { (cutover + 1.month).beginning_of_month }
    let(:product) { create(:product, price_cents: 100_00, native_type: "digital") }
    # The reported month is past both cutovers, so its chargebacks are event-dated.
    let(:chargeback_event_time) { report_month_start + 10.days }
    let(:dispute_won_time) { report_month_start + 20.days }

    before do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/canada-monthly-batched-spec-#{SecureRandom.hex(18)}.csv")
      allow(s3_bucket_double).to receive(:object).and_return(@s3_object)
    end

    it "nets a pre-cutover partial refund into the sale from the preloaded refunds, matching an unloaded purchase" do
      sale_month = cutover - 2.months
      purchase = nil
      travel_to(sale_month + 3.days) do
        purchase = create_canadian_sale("txn_canada_pre_cutover")
        create(:refund, purchase:, amount_cents: 40_00, fee_cents: 12_00,
                        gumroad_tax_cents: 5_20, total_transaction_cents: 45_20)
        purchase.update!(stripe_partially_refunded: true)
      end

      statements = []
      payload = capturing_sql(statements) { read_report(sale_month.month, sale_month.year) }
      row = payload.find { |candidate| candidate[0] == purchase.external_id }

      # Purchase::Reportable nets a pre-cutover purchase's refunds from the association when it is
      # loaded and from SQL when it is not, and the sales leg hands it a preloaded batch. An
      # absent SUM is what says the in-memory branch is the one the report actually ran.
      expect(statements.grep(/SELECT SUM\(.*FROM `refunds`/)).to be_empty

      unloaded = Purchase.find(purchase.id)
      expect(unloaded.refunds).not_to be_loaded
      unloaded_statements = []
      unloaded_price_cents = capturing_sql(unloaded_statements) { unloaded.price_cents_for_tax_reporting }
      # Positive control: the unloaded copy must take the SQL branch, or the absent-SUM checks prove nothing.
      expect(unloaded_statements.grep(/SELECT SUM\(.*FROM `refunds`/)).not_to be_empty
      expect(row[9]).to eq(money(unloaded.gumroad_tax_cents_for_tax_reporting))
      expect(row[11]).to eq(money(unloaded_price_cents))
      expect(row[12]).to eq(money(unloaded.fee_cents_for_tax_reporting))
      expect(row[14]).to eq(money(unloaded.total_cents_for_tax_reporting))
      # And that is the sale net of the pre-cutover refund, not the gross sale.
      expect(row[11]).to eq("60.00")
      expect(row[12]).to eq("18.00") # 30.00 of fee less the 12.00 the refund returned
    end

    it "reads the same number of times when the month holds more sales and refunds" do
      2.times { |index| create_canadian_sale_and_refund_in_report_month("txn_canada_base#{index}") }
      small_month = count_report_queries { read_report(report_month_start.month, report_month_start.year) }

      10.times { |index| create_canadian_sale_and_refund_in_report_month("txn_canada_growth#{index}") }

      # Six times the sales and refunds, still inside one batch: reads are per batch and per
      # association, never per row.
      expect(count_report_queries { read_report(report_month_start.month, report_month_start.year) }).to eq(small_month)
    end

    it "reads the same number of times when the month holds more chargebacks and dispute wins" do
      seed_chargeback_legs("base")
      small_month = count_report_queries { read_report(report_month_start.month, report_month_start.year) }

      4.times { |index| seed_chargeback_legs("growth#{index}") }

      payload = nil
      large_month = count_report_queries { payload = read_report(report_month_start.month, report_month_start.year) }

      # Five times the chargebacks and wins, still one batch per leg. Every reversal date is
      # resolved from the batch's preloaded dispute rows — the purchase's own, and the one
      # hanging off the Charge for the cart purchase that has no dispute of its own.
      expect(large_month).to eq(small_month)
      cart_rows = payload.select { |row| row[0] == @cart_won_purchase.external_id }
      expect(cart_rows.map { |row| row[1] }).to include(dispute_won_time.strftime("%m/%d/%Y"))
    end

    it "writes the same rows over several batches as it does in one" do
      3.times { |index| create_canadian_sale_and_refund_in_report_month("txn_canada_multi#{index}") }
      seed_chargeback_legs("multi")

      single_batch = nil
      single_batch_queries = count_report_queries { single_batch = read_report(report_month_start.month, report_month_start.year) }
      # Header, then three sale, three refund and three chargeback rows, then two dispute wins.
      expect(single_batch.length).to eq(12)

      # Two-row batches over three-row legs: every leg but the reversal leg crosses a slice
      # boundary, so a dropped or unpreloaded later slice shows up as missing rows or a SUM.
      stub_const("#{described_class}::ROW_BATCH_SIZE", 2)
      statements = []
      batched = nil
      batched_queries = count_report_queries do
        batched = capturing_sql(statements) { read_report(report_month_start.month, report_month_start.year) }
      end

      expect(batched).to eq(single_batch)
      expect(statements.grep(/SELECT SUM\(.*FROM `refunds`/)).to be_empty
      # Only the per-batch reads grow with the slice count; the per-leg id walks do not, so this
      # is a floor rather than a multiple.
      expect(batched_queries).to be > single_batch_queries
    end

    it "nets a refund made before the chargeback out of the clawback, from the preloaded refunds" do
      purchase = create_chargedback_purchase("txn_canada_cb_refunded")
      travel_to(report_month_start - 5.days) do
        create(:refund, purchase:, amount_cents: 40_00, fee_cents: 12_00,
                        gumroad_tax_cents: 5_20, total_transaction_cents: 45_20)
        purchase.update!(stripe_partially_refunded: true)
      end
      create(:dispute, purchase:, event_created_at: chargeback_event_time)

      statements = []
      payload = capturing_sql(statements) { read_report(report_month_start.month, report_month_start.year) }

      # The chargeback leg nets refunds through the same loaded/unloaded branch the sales leg
      # takes, off the same preloaded batch: an absent SUM is what says the in-memory branch ran.
      expect(statements.grep(/SELECT SUM\(.*FROM `refunds`/)).to be_empty

      # Header + the chargeback row: the sale and the refund both belong to earlier months.
      expect(payload.length).to eq(2)
      row = payload[1]
      expect(row[0]).to eq(purchase.external_id)
      expect(row[9]).to eq("-7.80")   # 13.00 of tax less the 5.20 the refund already returned
      expect(row[11]).to eq("-60.00") # 100.00 of price less the 40.00 already returned
      expect(row[12]).to eq("-18.00") # 30.00 of fee less the 12.00 already returned
      expect(row[14]).to eq("-67.80")
    end

    it "dates the re-add by the latest recorded win, not by the win that selected the month" do
      event_time = report_month_start - 4.days
      late_win = report_month_start + 1.month + 5.days
      purchase = create_chargedback_purchase("txn_canada_two_wins", reversed: true, event_time:)
      create(:dispute, purchase:, state: "won", event_created_at: event_time, won_at: report_month_start + 10.days)
      create(:dispute, purchase:, state: "won", event_created_at: event_time, won_at: late_win)

      # The earlier win selects the purchase into this month's reversal leg, but the resolved
      # reversal date is the later one, so nothing is re-added here (header only).
      expect(read_report(report_month_start.month, report_month_start.year).length).to eq(1)

      payload = read_report(late_win.month, late_win.year)
      expect(payload.length).to eq(2)
      expect(payload[1][0]).to eq(purchase.external_id)
      expect(payload[1][1]).to eq(late_win.strftime("%m/%d/%Y"))
      expect(payload[1][11]).to eq("100.00")
    end

    def money(cents)
      Money.new(cents).format(no_cents_if_whole: false, symbol: false)
    end

    def create_canadian_sale(stripe_transaction_id)
      create(:purchase, :with_custom_fee, link: product, price_cents: 100_00, fee_cents: 30_00,
                                          gumroad_tax_cents: 13_00, total_transaction_cents: 113_00,
                                          country: "Canada", state: "ON", ip_country: "Canada",
                                          stripe_transaction_id:)
    end

    def create_canadian_sale_and_refund_in_report_month(stripe_transaction_id)
      travel_to(report_month_start + 10.days) do
        purchase = create_canadian_sale(stripe_transaction_id)
        create(:refund, purchase:, amount_cents: 50_00, fee_cents: 15_00,
                        gumroad_tax_cents: 6_50, total_transaction_cents: 56_50)
        purchase.update!(stripe_partially_refunded: true)
      end
    end

    # A sale from the month before, charged back inside the reported month.
    def create_chargedback_purchase(stripe_transaction_id, reversed: false, event_time: chargeback_event_time)
      purchase = travel_to(report_month_start - 10.days) { create_canadian_sale(stripe_transaction_id) }
      purchase.update!(chargeback_date: event_time, chargeback_reversed: reversed)
      purchase
    end

    # One purchase per chargeback shape the two chargeback legs have to read a dispute for: a
    # lost chargeback (debit leg only), a win recorded on the purchase's own dispute, and a win
    # recorded only on the purchase's Charge — the fallback the reversal date resolves through.
    def seed_chargeback_legs(tag)
      lost = create_chargedback_purchase("txn_canada_cb_#{tag}")
      create(:dispute, purchase: lost, event_created_at: chargeback_event_time)

      won = create_chargedback_purchase("txn_canada_won_#{tag}", reversed: true)
      create(:dispute, purchase: won, state: "won", event_created_at: chargeback_event_time, won_at: dispute_won_time)

      @cart_won_purchase = create_chargedback_purchase("txn_canada_cart_#{tag}", reversed: true)
      charge = create(:charge)
      charge.purchases << @cart_won_purchase
      create(:dispute_on_charge, charge:, state: "won", event_created_at: chargeback_event_time, won_at: dispute_won_time)
    end

    def read_report(month, year)
      described_class.new.perform(month, year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      CSV.read(temp_file)
    ensure
      temp_file&.close(true)
    end

    def capturing_sql(statements, &block)
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
      end
      block.call
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    # Every table the legs read a row set from: the purchases/refunds they walk, the product and
    # TaxJar rows every row builder reads, and the dispute rows (directly, or through the
    # purchase's Charge) the chargeback legs resolve dates from.
    def count_report_queries(&block)
      queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries += 1 if /FROM `(purchases|refunds|disputes|charges|links|purchase_taxjar_infos)`/.match?(payload[:sql]) && payload[:name] != "SCHEMA" && !payload[:cached]
      end
      block.call
      queries
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
  end

  describe "chargeback event-date attribution" do
    let(:s3_bucket_double) do
      s3_bucket_double = double
      allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket).and_return(s3_bucket_double)
      s3_bucket_double
    end

    before :context do
      @s3_object = Aws::S3::Resource.new.bucket("gumroad-specs").object("specs/canada-monthly-chargeback-attribution-spec-#{SecureRandom.hex(18)}.csv")
    end

    let(:cutover) { Purchase::Reportable::CHARGEBACK_REPORTING_CUTOVER.beginning_of_day }

    before do
      product = create(:product, price_cents: 100_00, native_type: "digital")

      # Sold in the month before the cutover month; charged back post-cutover; dispute won
      # two months after the event. Each event must land in its own month's report.
      @sale_time = (cutover - 1.month).beginning_of_month + 14.days
      @event_time = cutover + 5.days
      @won_time = cutover + 2.months

      travel_to(@sale_time) do
        @chargedback_purchase = create(:purchase, link: product, price_cents: 100_00, fee_cents: 30_00,
                                                  gumroad_tax_cents: 13_00, total_transaction_cents: 113_00,
                                                  country: "Canada", state: "ON", ip_country: "Canada")

        # A legacy chargeback (event before the cutover): keeps the historical drop.
        @legacy_chargedback_purchase = create(:purchase, link: product, price_cents: 100_00, fee_cents: 30_00,
                                                         gumroad_tax_cents: 13_00, total_transaction_cents: 113_00,
                                                         country: "Canada", state: "ON", ip_country: "Canada")
      end

      @legacy_chargedback_purchase.update!(chargeback_date: cutover - 10.days)
      @chargedback_purchase.update!(chargeback_date: @event_time)

      travel_to(@won_time) do
        @chargedback_purchase.update!(chargeback_reversed: true)
        # One Dispute row carries both the formalization date (event_created_at, mirroring
        # chargeback_date) and the win date (won_at); the tax-period scopes resolve each leg's
        # window through it.
        create(:dispute, purchase: @chargedback_purchase, state: "won", event_created_at: @event_time, won_at: Time.current)
      end
    end

    def perform_and_read(month, year)
      expect(s3_bucket_double).to receive(:object).and_return(@s3_object)

      described_class.new.perform(month, year)

      temp_file = Tempfile.new("actual-file", encoding: "ascii-8bit")
      @s3_object.get(response_target: temp_file)
      temp_file.rewind
      CSV.read(temp_file)
    ensure
      temp_file&.close(true)
    end

    it "keeps the event-dated chargeback's sale in the purchase month and drops only the legacy one" do
      payload = perform_and_read(@sale_time.month, @sale_time.year)

      # Header + the event-dated purchase's sale row. The legacy chargeback stays dropped
      # (as filed); the chargeback legs belong to later months and must not leak backwards.
      expect(payload.length).to eq(2)
      expect(payload[1][0]).to eq(@chargedback_purchase.external_id)
      expect(payload[1][11]).to eq("100.00") # Price, gross
    end

    it "reports the chargeback as a negative row in the month the dispute was formalized" do
      payload = perform_and_read(@event_time.month, @event_time.year)

      expect(payload.length).to eq(2)
      row = payload[1]
      expect(row[0]).to eq(@chargedback_purchase.external_id)
      expect(row[1]).to eq(@event_time.strftime("%m/%d/%Y"))
      expect(row[9]).to eq("-13.00")   # Calculated Tax Amount
      expect(row[10]).to eq("-13.00")  # Tax Collected by Gumroad
      expect(row[11]).to eq("-100.00") # Price
      expect(row[12]).to eq("-13.70")  # Gumroad Fee (the factory recalculates fees on build)
      expect(row[14]).to eq("-113.00") # Total
    end

    it "adds the won dispute back as a positive row in the month of won_at" do
      payload = perform_and_read(@won_time.month, @won_time.year)

      expect(payload.length).to eq(2)
      row = payload[1]
      expect(row[0]).to eq(@chargedback_purchase.external_id)
      expect(row[1]).to eq(@won_time.strftime("%m/%d/%Y"))
      expect(row[11]).to eq("100.00")
      expect(row[14]).to eq("113.00")
    end

    it "omits a chargeback fully refunded before the dispute, since nothing is left to claw back" do
      fully_refunded = nil
      travel_to(@sale_time) do
        fully_refunded = create(:purchase, link: @chargedback_purchase.link,
                                           price_cents: 100_00, fee_cents: 30_00, gumroad_tax_cents: 13_00,
                                           total_transaction_cents: 113_00,
                                           country: "Canada", state: "ON", ip_country: "Canada")
        # Refund every amount (price, fee, tax, total) before the chargeback, so the dispute
        # has nothing left to claw back and every *_for_chargeback_reporting value is zero.
        create(:refund, purchase: fully_refunded,
                        amount_cents: fully_refunded.price_cents,
                        fee_cents: fully_refunded.fee_cents,
                        gumroad_tax_cents: fully_refunded.gumroad_tax_cents,
                        creator_tax_cents: fully_refunded.tax_cents,
                        total_transaction_cents: fully_refunded.total_transaction_cents)
      end
      fully_refunded.update!(chargeback_date: @event_time)
      create(:dispute, purchase: fully_refunded, event_created_at: @event_time)

      payload = perform_and_read(@event_time.month, @event_time.year)

      ids = payload.drop(1).map { |row| row[0] }
      expect(ids).to include(@chargedback_purchase.external_id) # a real clawback is still reported
      expect(ids).not_to include(fully_refunded.external_id)    # zero clawback ⇒ no spurious all-zero row
    end
  end
end
