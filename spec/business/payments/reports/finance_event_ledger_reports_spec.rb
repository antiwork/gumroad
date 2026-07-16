# frozen_string_literal: true

describe FinanceEventLedgerReports do
  # The purchase factory resolves its merchant account via MerchantAccount.gumroad,
  # which only exists where the DB has been seeded — create Gumroad's own accounts so
  # successful-purchase factories validate everywhere.
  before do
    create(:merchant_account, user: nil) if MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).nil?
    create(:merchant_account_paypal, user: nil) if MerchantAccount.gumroad(PaypalChargeProcessor.charge_processor_id).nil?
  end

  def line(report, processor, item)
    report["processors"].find { |entry| entry["processor"] == processor }.fetch(item)
  end

  describe ".daily_report" do
    it "raises unless the requested day has fully ended" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        expect { described_class.daily_report(Date.new(2026, 7, 15)) }.to raise_error(ArgumentError, /completed UTC day/)
        expect { described_class.daily_report(Date.new(2026, 7, 16)) }.to raise_error(ArgumentError, /completed UTC day/)
        expect { described_class.daily_report(Date.new(2026, 7, 14)) }.not_to raise_error
      end
    end

    it "books a purchase to its succeeded day and its refund to the refund day, without rewriting the closed day" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        purchase = create(:purchase, created_at: Time.utc(2026, 7, 1, 10), succeeded_at: Time.utc(2026, 7, 1, 10))
        day_one_before_refund = described_class.daily_report(Date.new(2026, 7, 1))

        # A full refund nine days later: flips the flag the monthly snapshot report
        # filters on, and books a refund row.
        purchase.update!(stripe_refunded: true)
        create(:refund, purchase:, created_at: Time.utc(2026, 7, 10, 9), fee_cents: purchase.fee_cents)

        day_one = described_class.daily_report(Date.new(2026, 7, 1))
        expect(day_one).to eq(day_one_before_refund)
        expect(line(day_one, "Stripe", "funds_received")).to eq(
          "count" => 1,
          "total_transaction_cents" => purchase.total_transaction_cents,
          "gumroad_tax_cents" => purchase.gumroad_tax_cents,
          "affiliate_credit_cents" => purchase.affiliate_credit_cents,
          "fee_cents" => purchase.fee_cents,
        )

        refunds_line = line(described_class.daily_report(Date.new(2026, 7, 10)), "Stripe", "refunds_issued")
        expect(refunds_line["count"]).to eq(1)
        expect(refunds_line["total_transaction_cents"]).to eq(purchase.total_transaction_cents)
        expect(refunds_line["fee_cents"]).to eq(purchase.fee_cents)
        # The purchase succeeded in the same month as the refund, so this is contra
        # revenue for the month in progress, not a reversal of an earlier period.
        expect(refunds_line["deferred"]["count"]).to eq(0)
        expect(refunds_line["current_month"]["count"]).to eq(1)

        # Neighboring days carry neither event.
        expect(line(described_class.daily_report(Date.new(2026, 7, 2)), "Stripe", "funds_received")["count"]).to eq(0)
        expect(line(described_class.daily_report(Date.new(2026, 7, 9)), "Stripe", "refunds_issued")["count"]).to eq(0)
      end
    end

    it "counts a refund of a prior-month purchase in the deferred bucket" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        purchase = create(:purchase, created_at: Time.utc(2026, 6, 10), succeeded_at: Time.utc(2026, 6, 10))
        create(:refund, purchase:, created_at: Time.utc(2026, 7, 5, 9))

        refunds_line = line(described_class.daily_report(Date.new(2026, 7, 5)), "Stripe", "refunds_issued")
        expect(refunds_line["count"]).to eq(1)
        expect(refunds_line["deferred"]["count"]).to eq(1)
        expect(refunds_line["deferred"]["total_transaction_cents"]).to eq(purchase.total_transaction_cents)
        expect(refunds_line["current_month"]["count"]).to eq(0)
      end
    end

    it "prorates affiliate credit on partial refunds the same way the monthly report does" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        product = create(:product, price_cents: 1000)
        purchase = create(:purchase, link: product, created_at: Time.utc(2026, 7, 2), succeeded_at: Time.utc(2026, 7, 2))
        purchase.update_column(:affiliate_credit_cents, 300)
        create(:refund, purchase:, amount_cents: 500, total_transaction_cents: 500, gumroad_tax_cents: 0, created_at: Time.utc(2026, 7, 6, 9))

        refunds_line = line(described_class.daily_report(Date.new(2026, 7, 6)), "Stripe", "refunds_issued")
        expect(refunds_line["affiliate_credit_cents"]).to eq(150)
      end
    end

    it "partitions a month: summing the daily reports equals the month's event totals" do
      travel_to(Time.utc(2026, 8, 5, 12)) do
        create(:purchase, created_at: Time.utc(2026, 6, 30, 23, 59, 59), succeeded_at: Time.utc(2026, 6, 30, 23, 59, 59))
        create(:purchase, created_at: Time.utc(2026, 7, 1), succeeded_at: Time.utc(2026, 7, 1))
        create(:purchase, created_at: Time.utc(2026, 7, 31, 23, 59, 59), succeeded_at: Time.utc(2026, 7, 31, 23, 59, 59))
        create(:purchase, created_at: Time.utc(2026, 8, 1), succeeded_at: Time.utc(2026, 8, 1))

        july_days = (Date.new(2026, 7, 1)..Date.new(2026, 7, 31)).map do |day|
          line(described_class.daily_report(day), "Stripe", "funds_received")
        end
        expect(july_days.sum { |funds| funds["count"] }).to eq(2)
        expect(july_days.sum { |funds| funds["total_transaction_cents"] }).to eq(Purchase.where(succeeded_at: DateTime.new(2026, 7, 1)...DateTime.new(2026, 8, 1)).sum(:total_transaction_cents))

        # The boundary events landed on their own days, exactly once.
        expect(line(described_class.daily_report(Date.new(2026, 6, 30)), "Stripe", "funds_received")["count"]).to eq(1)
        expect(line(described_class.daily_report(Date.new(2026, 8, 1)), "Stripe", "funds_received")["count"]).to eq(1)
      end
    end

    it "books dispute formalization and reversal as separate events on their own days" do
      travel_to(Time.utc(2026, 8, 10, 12)) do
        purchase = create(:purchase, created_at: Time.utc(2026, 6, 10), succeeded_at: Time.utc(2026, 6, 10))
        dispute = create(:dispute_formalized, purchase:, formalized_at: Time.utc(2026, 7, 3, 8))

        day_three = described_class.daily_report(Date.new(2026, 7, 3))
        formalized_line = line(day_three, "Stripe", "disputes_formalized")
        expect(formalized_line["count"]).to eq(1)
        expect(formalized_line["total_transaction_cents"]).to eq(purchase.total_transaction_cents)
        # A June purchase disputed in July reverses revenue from a closed period.
        expect(formalized_line["deferred"]["count"]).to eq(1)

        # The state machine stamps won_at with the processing time; pin it to the win
        # day since nested travel_to is not allowed here.
        dispute.mark_won!
        dispute.update!(won_at: Time.utc(2026, 7, 9, 14))

        # The win is a new positive event on its own day; the formalized day replays
        # bit-identical instead of being retroactively rewritten.
        expect(described_class.daily_report(Date.new(2026, 7, 3))).to eq(day_three)
        reversed_line = line(described_class.daily_report(Date.new(2026, 7, 9)), "Stripe", "disputes_reversed")
        expect(reversed_line["count"]).to eq(1)
        expect(reversed_line["total_transaction_cents"]).to eq(purchase.total_transaction_cents)
      end
    end

    it "includes disputes attached to a combined Charge, which the monthly report missed" do
      travel_to(Time.utc(2026, 8, 10, 12)) do
        purchases = create_list(:purchase, 2, created_at: Time.utc(2026, 7, 2), succeeded_at: Time.utc(2026, 7, 2))
        charge = create(:charge)
        purchases.each { |purchase| charge.purchases << purchase }
        create(:dispute_on_charge, charge:, state: "formalized", formalized_at: Time.utc(2026, 7, 5, 8))

        formalized_line = line(described_class.daily_report(Date.new(2026, 7, 5)), "Stripe", "disputes_formalized")
        expect(formalized_line["count"]).to eq(2)
        expect(formalized_line["total_transaction_cents"]).to eq(purchases.sum(&:total_transaction_cents))
        expect(formalized_line["current_month"]["count"]).to eq(2)
      end
    end

    it "books the reversal of a failed refund as its own compensating event, leaving the refund's day untouched" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        purchase = create(:purchase, created_at: Time.utc(2026, 7, 1, 10), succeeded_at: Time.utc(2026, 7, 1, 10))
        refund = create(:refund, purchase:, created_at: Time.utc(2026, 7, 3, 9), fee_cents: purchase.fee_cents)
        refund_day = described_class.daily_report(Date.new(2026, 7, 3))
        expect(line(refund_day, "Stripe", "refunds_issued")["count"]).to eq(1)
        expect(line(refund_day, "Stripe", "refund_reversals")["count"]).to eq(0)

        # The refund fails at the buyer's bank a week later and the service reverses
        # its balance debits, stamping the reversal time.
        refund.update!(status: "failed")
        refund.balance_reversed_on_failure = true
        refund.balance_reversed_on_failure_at = Time.utc(2026, 7, 10, 14).iso8601
        refund.save!

        # The refund's own day replays bit-identical — its issued event is immutable.
        expect(described_class.daily_report(Date.new(2026, 7, 3))).to eq(refund_day)

        # The reversal is a new dated event on the day the money came back.
        reversal_line = line(described_class.daily_report(Date.new(2026, 7, 10)), "Stripe", "refund_reversals")
        expect(reversal_line["count"]).to eq(1)
        expect(reversal_line["total_transaction_cents"]).to eq(purchase.total_transaction_cents)
        expect(reversal_line["fee_cents"]).to eq(purchase.fee_cents)
        # The purchase succeeded in the reversal's own month, so this compensates
        # revenue for the month in progress rather than a closed period.
        expect(reversal_line["deferred"]["count"]).to eq(0)
        expect(reversal_line["current_month"]["count"]).to eq(1)

        # Neighboring days carry no reversal.
        expect(line(described_class.daily_report(Date.new(2026, 7, 9)), "Stripe", "refund_reversals")["count"]).to eq(0)
        expect(line(described_class.daily_report(Date.new(2026, 7, 11)), "Stripe", "refund_reversals")["count"]).to eq(0)
      end
    end

    it "does not book a reversal event for a failed refund that was never reversed" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        purchase = create(:purchase, created_at: Time.utc(2026, 7, 1, 10), succeeded_at: Time.utc(2026, 7, 1, 10))
        create(:refund, purchase:, created_at: Time.utc(2026, 7, 3, 9), status: "failed")

        (Date.new(2026, 7, 2)..Date.new(2026, 7, 14)).each do |day|
          expect(line(described_class.daily_report(day), "Stripe", "refund_reversals")["count"]).to eq(0)
        end
      end
    end

    it "splits PayPal wallet money from everything else, matching the monthly report's buckets" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        succeeded_at = Time.utc(2026, 7, 4, 10)
        paypal_purchase = create(:purchase, card_type: "paypal", charge_processor_id: PaypalChargeProcessor.charge_processor_id, created_at: succeeded_at, succeeded_at:)
        stripe_purchase = create(:purchase, created_at: succeeded_at, succeeded_at:)

        report = described_class.daily_report(Date.new(2026, 7, 4))
        expect(line(report, "PayPal", "funds_received")["count"]).to eq(1)
        expect(line(report, "PayPal", "funds_received")["total_transaction_cents"]).to eq(paypal_purchase.total_transaction_cents)
        expect(line(report, "Stripe", "funds_received")["count"]).to eq(1)
        expect(line(report, "Stripe", "funds_received")["total_transaction_cents"]).to eq(stripe_purchase.total_transaction_cents)
      end
    end

    it "stamps the payload with its version and exact UTC window" do
      travel_to(Time.utc(2026, 7, 15, 12)) do
        report = described_class.daily_report(Date.new(2026, 7, 7))
        expect(report["report_version"]).to eq(described_class::REPORT_VERSION)
        expect(report["date"]).to eq("2026-07-07")
        expect(report["window_start"]).to eq("2026-07-07T00:00:00+00:00")
        expect(report["window_end"]).to eq("2026-07-08T00:00:00+00:00")
      end
    end
  end
end
