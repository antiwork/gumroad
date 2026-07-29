# frozen_string_literal: true

require "spec_helper"

describe TaxRemittances::StageQuarterlyDrafts do
  def create_taxed_purchase(product, attrs = {})
    gumroad_tax_cents = attrs.delete(:gumroad_tax_cents) || 0
    purchase = create(:purchase, link: product, **attrs)
    purchase.update_columns(gumroad_tax_cents:, total_transaction_cents: purchase.price_cents + gumroad_tax_cents)
    purchase
  end

  # A remittance for an authority this quarter's purchases never touch, so the
  # calculator never produces a liability for it — the "vanished authority"
  # shape.
  def create_hmrc_remittance(status: "draft")
    TaxRemittance.create!(
      authority: "HMRC",
      jurisdiction: "GB",
      period:,
      currency: "GBP",
      usd_amount_cents: 25_00,
      target_amount_cents: 20_00,
      rail: "wise",
      attempt: 1,
      status: "draft",
    ).tap { advance_to(_1, status) unless status == "draft" }
  end

  # Walks a draft through the lifecycle to the requested status, since the model
  # only allows the real transitions. `paid_at` is required from `sent` onward.
  def advance_to(remittance, status)
    return remittance if remittance.status == status

    case status
    when "pending_approval"
      remittance.submit_for_approval!(
        reviewed_amount_cents: remittance.usd_amount_cents,
        reviewed_target_amount_cents: remittance.target_amount_cents,
      )
    when "cancelled"
      remittance.update!(status: "cancelled")
    when "failed"
      remittance.update!(status: "failed")
    else
      advance_to(remittance, "pending_approval")
      remittance.update!(status: "funded")
      return remittance if status == "funded"

      remittance.update!(status: "sent", paid_at: Time.current)
      remittance.update!(status:) unless status == "sent"
    end

    remittance
  end

  let(:period) { "2027-Q1" }
  let(:in_period) { Time.find_zone("UTC").local(2027, 2, 10) }
  let(:product) { create(:product, price_cents: 100_00, native_type: "digital") }

  before do
    travel_to(in_period) do
      create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 19_00)
      create_taxed_purchase(product, country: "France", gumroad_tax_cents: 20_00)
      create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 10_00)
    end
  end

  it "rejects a rail the tax_remittances table doesn't model" do
    expect { described_class.new(period, rail: "paypal") }.to raise_error(ArgumentError, /unknown rail/)
  end

  it "stages one draft per authority with the computed amount" do
    service = described_class.new(period).process

    expect(service.created.size).to eq(2)
    expect(service.skipped).to be_empty

    oss = TaxRemittance.find_by!(authority: "Irish Revenue (EU VAT OSS)", period:)
    expect(oss.usd_amount_cents).to eq(39_00) # Germany + France, one OSS payment
    expect(oss.jurisdiction).to eq("EU_OSS")
    expect(oss.currency).to eq("EUR")
    expect(oss.attempt).to eq(1)

    ato = TaxRemittance.find_by!(authority: "Australian Taxation Office", period:)
    expect(ato.usd_amount_cents).to eq(10_00)
    expect(ato.currency).to eq("AUD")
  end

  # Nothing this service creates may be capable of moving money on its own.
  it "creates every row as an unpaid draft" do
    described_class.new(period).process

    rows = TaxRemittance.for_period(period)
    expect(rows.map(&:status).uniq).to eq(["draft"])
    expect(rows.map(&:paid_at).compact).to be_empty
    expect(rows.map(&:transfer_id).compact).to be_empty
  end

  it "defaults to the Wise rail but accepts another one" do
    described_class.new(period).process
    expect(TaxRemittance.for_period(period).map(&:rail).uniq).to eq(["wise"])

    TaxRemittance.for_period(period).destroy_all

    described_class.new(period, rail: "stripe_global_payouts").process
    expect(TaxRemittance.for_period(period).map(&:rail).uniq).to eq(["stripe_global_payouts"])
  end

  it "records how each amount was derived so a reviewer needn't re-run the calculator" do
    described_class.new(period).process

    oss = TaxRemittance.find_by!(authority: "Irish Revenue (EU VAT OSS)", period:)
    expect(oss.notes).to include("Sales $39.00")
    expect(oss.notes).to include("net $39.00")
    expect(oss.notes).to include("DE, FR")
  end

  # A deduction of a negative amount is a real quarter shape: a chargeback reversal landing this
  # quarter against a chargeback booked in an earlier one adds the tax back, so chargebacks net
  # below zero. The note used to hardcode a leading minus and render "chargebacks -$-5.00", which
  # a human reconciling a filing has to stop and decode before they can trust the figure.
  it "renders a negative deduction as one signed figure, not a double negative" do
    service = described_class.new(period)
    liability = Struct.new(:authority, :jurisdiction, :currency, :sales_tax_cents, :refunded_tax_cents,
                           :chargeback_tax_cents, :tax_collected_cents, :country_codes, keyword_init: true)
                     .new(authority: "Australian Taxation Office", jurisdiction: "AU", currency: "AUD",
                          sales_tax_cents: 10_00, refunded_tax_cents: 0, chargeback_tax_cents: -5_00,
                          tax_collected_cents: 15_00, country_codes: ["AU"])

    notes = service.send(:draft_notes, liability)

    expect(notes).to include("chargebacks +$5.00")
    expect(notes).not_to include("-$-")
    # The ordinary positive deduction still reads as a subtraction.
    expect(service.send(:draft_notes, liability.tap { _1.chargeback_tax_cents = 5_00 }))
      .to include("chargebacks -$5.00")
  end

  describe "re-running" do
    # Safe to run repeatedly as a quarter closes: a filing that already has a
    # draft must not get a second one.
    it "skips a filing that already has a draft rather than duplicating it" do
      described_class.new(period).process
      second = described_class.new(period).process

      expect(second.created).to be_empty
      expect(second.skipped.map { _1[:authority] }).to match_array(
        ["Irish Revenue (EU VAT OSS)", "Australian Taxation Office"]
      )
      expect(TaxRemittance.for_period(period).count).to eq(2)
    end

    # A quarter keeps settling after the first staging run, so a re-run has to
    # correct the draft rather than leave a reviewer looking at the old number.
    it "refreshes an untouched draft when the quarter's liability has changed" do
      described_class.new(period).process
      ato = TaxRemittance.find_by!(authority: "Australian Taxation Office", period:)
      expect(ato.usd_amount_cents).to eq(10_00)

      travel_to(in_period) do
        create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 5_00)
      end

      service = described_class.new(period).process

      expect(service.created).to be_empty
      expect(ato.reload.usd_amount_cents).to eq(15_00)
      expect(ato.notes).to include("net $15.00")
      expect(ato.status).to eq("draft")
      expect(ato.attempt).to eq(1)
      # Still one row for the filing — a refresh must not become a second draft.
      expect(TaxRemittance.where(authority: "Australian Taxation Office", period:).count).to eq(1)

      refreshed = service.refreshed.find { _1[:authority] == "Australian Taxation Office" }
      expect(refreshed[:from_cents]).to eq(10_00)
      expect(refreshed[:to_cents]).to eq(15_00)
    end

    it "reports a draft whose amount already matches as an untouched skip" do
      described_class.new(period).process
      service = described_class.new(period).process

      expect(service.refreshed).to be_empty
      expect(service.skipped.find { _1[:authority] == "Australian Taxation Office" }[:reason])
        .to include("already matches")
    end

    # Once a human is working the row, its amount is theirs. Silently rewriting
    # a number someone is reviewing is worse than telling them it moved.
    it "leaves a row a human has picked up alone and reports the drift" do
      described_class.new(period).process
      ato = TaxRemittance.find_by!(authority: "Australian Taxation Office", period:)
      ato.update!(status: "pending_approval")

      travel_to(in_period) do
        create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 5_00)
      end

      service = described_class.new(period).process

      expect(ato.reload.usd_amount_cents).to eq(10_00)
      expect(ato.status).to eq("pending_approval")

      skipped = service.skipped.find { _1[:authority] == "Australian Taxation Office" }
      expect(skipped[:reason]).to include("pending_approval")
      expect(skipped[:stale_amount]).to eq(recorded_cents: 10_00, computed_cents: 15_00)
    end

    # Same rule, but for the narrow window where the reviewer's transition
    # lands *while* this service is mid-refresh: the row was a draft when we
    # looked at it and belongs to a human by the time we write. The refresh has
    # to notice and back off, or an approver's number gets rewritten under them
    # and the run reports it as a clean refresh. The reviewer's commit is
    # simulated by flipping the row's status after the service has read it but
    # before it writes.
    it "backs off when the row is picked up by a human mid-refresh" do
      described_class.new(period).process
      ato = TaxRemittance.find_by!(authority: "Australian Taxation Office", period:)

      travel_to(in_period) do
        create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 5_00)
      end

      service = described_class.new(period)
      # draft_notes runs after the row has been read and before it is written,
      # which is exactly the window a reviewer can commit in.
      allow(service).to receive(:draft_notes).and_wrap_original do |original, liability|
        if liability.authority == "Australian Taxation Office"
          TaxRemittance.where(id: ato.id, status: "draft").update_all(status: "pending_approval")
        end
        original.call(liability)
      end

      service.process

      # The human's row is untouched: their amount, their status.
      expect(ato.reload.usd_amount_cents).to eq(10_00)
      expect(ato.status).to eq("pending_approval")
      expect(ato.notes).to include("net $10.00")

      # And the run says so rather than claiming a refresh it didn't make.
      expect(service.refreshed.map { _1[:authority] }).not_to include("Australian Taxation Office")
      skipped = service.skipped.find { _1[:authority] == "Australian Taxation Office" }
      expect(skipped[:reason]).to include("pending_approval")
      expect(skipped[:stale_amount]).to eq(recorded_cents: 10_00, computed_cents: 15_00)
    end

    # The other ordering of the same race, and the one the row lock alone does
    # not solve: the refresh commits FIRST, and the reviewer submits afterwards
    # holding the amount they were shown before it moved. The lock makes the
    # write safe but says nothing about whether the human saw it, so the
    # approval transition itself has to re-check. Submitting the stale amount
    # is refused; submitting the refreshed one goes through.
    it "refuses a reviewer's submission that carries an amount the refresh replaced" do
      described_class.new(period).process
      ato = TaxRemittance.find_by!(authority: "Australian Taxation Office", period:)
      # An authority is paid in its own currency, so the target amount has to
      # be recorded before the row can enter approval at all.
      ato.record_target_amount!(14_00)
      # What the reviewer had on screen before the re-run.
      reviewed_amount_cents = ato.usd_amount_cents
      expect(reviewed_amount_cents).to eq(10_00)

      travel_to(in_period) do
        create_taxed_purchase(product, country: "Australia", gumroad_tax_cents: 5_00)
      end

      service = described_class.new(period).process
      expect(service.refreshed.map { _1[:authority] }).to include("Australian Taxation Office")
      expect(ato.reload.usd_amount_cents).to eq(15_00)

      expect { ato.submit_for_approval!(reviewed_amount_cents:, reviewed_target_amount_cents: 14_00) }
        .to raise_error(TaxRemittance::AmountChangedSinceReview)

      # The row stays a draft: nothing unreviewed entered the approval flow.
      expect(ato.reload.status).to eq("draft")

      # Once the reviewer re-reads the refreshed amount, the submission lands.
      ato.submit_for_approval!(reviewed_amount_cents: 15_00, reviewed_target_amount_cents: 14_00)
      expect(ato.reload.status).to eq("pending_approval")
    end

    # The strongest case: a filing already PAID must never be re-staged, or a
    # re-run at the wrong moment would propose paying an authority twice.
    it "never stages or rewrites a filing that was already paid" do
      described_class.new(period).process
      oss = TaxRemittance.find_by!(authority: "Irish Revenue (EU VAT OSS)", period:)
      oss.update!(status: "pending_approval")
      oss.update!(status: "funded")
      oss.update!(status: "sent", paid_at: Time.current)
      oss.update!(status: "completed")

      travel_to(in_period) do
        create_taxed_purchase(product, country: "Germany", gumroad_tax_cents: 19_00)
      end

      service = described_class.new(period).process

      expect(service.created).to be_empty
      expect(service.refreshed).to be_empty
      expect(oss.reload.usd_amount_cents).to eq(39_00)
      expect(service.skipped.find { _1[:authority] == "Irish Revenue (EU VAT OSS)" }[:reason])
        .to include("completed")
      expect(TaxRemittance.where(authority: "Irish Revenue (EU VAT OSS)", period:).count).to eq(1)
    end

    # An authority can drop out of the computation entirely once refunds cancel
    # its collections, and then nothing in the staging loop ever looks at its
    # draft again.
    it "surfaces a draft for an authority the quarter no longer owes, and blocks on it" do
      hmrc = create_hmrc_remittance

      service = described_class.new(period).process

      expect(service.vanished_authorities.map { _1[:authority] }).to eq(["HMRC"])
      expect(service.vanished_authorities.first[:recorded_cents]).to eq(25_00)
      expect(service.vanished_authorities.first[:status]).to eq("draft")
      expect(service).to be_blocking
      # Reported, not deleted — a draft can't move money, and cancelling a
      # filing is a human's call.
      expect(hmrc.reload.status).to eq("draft")
    end

    # The case a draft-only check missed completely: a human has already moved
    # the row along, so it is heading toward a payment the quarter no longer
    # says is owed, and nothing anywhere said so.
    %w[pending_approval funded sent].each do |status|
      it "surfaces a #{status} remittance for an authority the quarter no longer owes, without touching it" do
        hmrc = create_hmrc_remittance
        advance_to(hmrc, status)

        service = described_class.new(period).process

        vanished = service.vanished_authorities.find { _1[:authority] == "HMRC" }
        expect(vanished[:status]).to eq(status)
        expect(vanished[:recorded_cents]).to eq(25_00)
        expect(vanished[:action_required]).to be_present
        expect(service).to be_blocking
        expect(service.blocking_diagnostics).to include(vanished)

        # Nothing is cancelled or rewritten: deciding between withdrawing,
        # adjusting the next return, and reconciling a sent payment is a
        # filing decision.
        expect(hmrc.reload.status).to eq(status)
        expect(hmrc.usd_amount_cents).to eq(25_00)
      end
    end

    # Terminal rows are history, not a live payment heading out the door.
    # Flagging a completed filing every run would train a reviewer to ignore
    # the diagnostic that matters.
    %w[completed failed cancelled].each do |status|
      it "leaves a #{status} remittance out of the vanished-authority report" do
        hmrc = create_hmrc_remittance
        advance_to(hmrc, status)

        service = described_class.new(period).process

        expect(service.vanished_authorities.map { _1[:authority] }).not_to include("HMRC")
      end
    end

    # An authority whose refunds exceeded its collections owes us rather than
    # the reverse. That is why its liability disappeared, so the credit is
    # reported beside the vanished row instead of being left for a reviewer to
    # work out.
    it "reports a negative position as an authority credit alongside the vanished row" do
      hmrc = create_hmrc_remittance
      advance_to(hmrc, "pending_approval")

      travel_to(in_period) do
        gb_purchase = create_taxed_purchase(product, country: "United Kingdom", gumroad_tax_cents: 20_00)
        # A refund larger than what was collected in the quarter: this
        # authority's net position is a credit.
        create(:refund, purchase: gb_purchase, total_transaction_cents: 120_00, gumroad_tax_cents: 30_00)
      end

      service = described_class.new(period).process

      credit = service.coverage_gaps[:authority_credits].find { _1.authority == "HMRC" }
      expect(credit.credit_cents).to eq(10_00)
      expect(credit.currency).to eq("GBP")

      vanished = service.vanished_authorities.find { _1[:authority] == "HMRC" }
      expect(vanished[:credit_cents]).to eq(10_00)

      # A credit is never staged as a payment.
      expect(service.created.map(&:authority)).not_to include("HMRC")
    end

    # A failed attempt is retryable, so staging continues the filing's
    # numbering instead of colliding on attempt 1 or restarting history.
    it "stages the next attempt after a failed one" do
      described_class.new(period).process
      TaxRemittance.find_by!(authority: "Australian Taxation Office", period:).update!(status: "failed")

      service = described_class.new(period).process

      staged = service.created.find { _1.authority == "Australian Taxation Office" }
      expect(staged.attempt).to eq(2)
      expect(staged.status).to eq("draft")
      # The failed attempt is preserved rather than overwritten.
      expect(TaxRemittance.where(authority: "Australian Taxation Office", period:).pluck(:status))
        .to match_array(%w[failed draft])
    end
    # A caller that retries after a transient failure must be able to trust the report it reads.
    # The result lists used to be built in the constructor and only appended to, so a second
    # process call returned the first run's rows alongside its own — a staging report claiming a
    # filing was created twice when it was created once.
    it "reports only the work of the latest run when reused" do
      service = described_class.new(period)
      service.process

      expect(service.created.size).to eq(2)

      service.process

      # Nothing new to create the second time round, so both filings are skipped as already staged
      # and the created list from the first pass is gone rather than carried forward.
      expect(service.created).to be_empty
      expect(service.skipped.size).to eq(2)
      expect(TaxRemittance.for_period(period).count).to eq(2)
    end

    # "raced by a concurrent write" is a reason a reviewer is meant to shrug at, so an ordinary
    # validation failure wearing it would leave the filing unstaged every single run with nothing
    # in the report explaining why.
    it "reports a validation failure as itself, not as a race" do
      allow(TaxRemittance).to receive(:create!)
        .and_raise(ActiveRecord::RecordInvalid.new(TaxRemittance.new))

      service = described_class.new(period).process

      expect(service.created).to be_empty
      expect(service.skipped.size).to eq(2)
      service.skipped.each do |skip|
        expect(skip[:reason]).to include("could not stage draft")
        expect(skip[:reason]).not_to include("raced by a concurrent write")
      end
    end

    # And the genuine race still reads as one: a live row for this filing exists, so whoever created
    # it is the one to use and there is nothing here for a human to fix.
    it "still reports a real race as a race" do
      described_class.new(period).process
      TaxRemittance.for_period(period).update_all(status: "failed")

      # A failed attempt is retryable, so staging tries to create the next attempt — but a live row
      # appearing underneath it means someone else got there first.
      #
      # The concurrent writer is simulated inside the `create!` stub rather than by stubbing the
      # lookup queries: the row it lands is a real one, so the service's own re-check does real SQL
      # and we are testing the branch the way production reaches it. Flipping only *this* filing's
      # rows keeps the other authority on the same path instead of turning its skip into an
      # "already staged" one.
      allow(TaxRemittance).to receive(:create!) do |attributes|
        TaxRemittance.where(authority: attributes[:authority], period: attributes[:period])
                     .update_all(status: "pending_approval")
        raise ActiveRecord::RecordNotUnique, "duplicate key"
      end

      service = described_class.new(period).process

      expect(service.skipped.map { _1[:reason] }).to all(include("raced by a concurrent write"))
    end
  end

  describe "coverage gaps" do
    it "passes through countries with collected tax and no mapped authority" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Canada", state: "ON", gumroad_tax_cents: 13_00)
      end

      service = described_class.new(period).process

      expect(service.coverage_gaps[:unmapped_countries]).to include(["CA", 13_00])
      # And no draft is invented for a country we have no authority for.
      expect(TaxRemittance.for_period(period).pluck(:jurisdiction)).not_to include("CA")
    end

    it "passes through country names that resolve to no country" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: "Slovak Republic", gumroad_tax_cents: 8_00)
      end

      service = described_class.new(period).process

      expect(service.coverage_gaps[:unresolved_country_names]).to eq({ "Slovak Republic" => 8_00 })
    end

    # A purchase with no country at all can't be filed anywhere, so the amount
    # has to reach whoever runs this rather than staying inside the calculator.
    it "passes through tax on purchases with no country at all" do
      travel_to(in_period) do
        create_taxed_purchase(product, country: nil, ip_country: nil, gumroad_tax_cents: 6_00)
      end

      service = described_class.new(period).process

      expect(service.coverage_gaps[:countryless_tax_cents]).to eq(6_00)
      # And it is not invented as a payment to anyone.
      expect(service.created.sum { _1.usd_amount_cents }).to eq(39_00 + 10_00)
    end
  end

  it "stages nothing for a quarter with no collected tax" do
    service = described_class.new("2027-Q3").process

    expect(service.created).to be_empty
    expect(TaxRemittance.for_period("2027-Q3")).to be_empty
  end
end
