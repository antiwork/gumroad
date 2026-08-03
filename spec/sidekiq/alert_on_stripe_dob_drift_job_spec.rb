# frozen_string_literal: true

require "spec_helper"

describe AlertOnStripeDobDriftJob do
  let(:seller) { create(:user) }

  def gumroad_managed_account(user: seller)
    create(:merchant_account, user:,
                              charge_processor_id: StripeChargeProcessor.charge_processor_id,
                              charge_processor_merchant_id: "acct_dobdrift_#{SecureRandom.hex(6)}",
                              country: "RO")
  end

  def compliance_info(birthday:, user: seller, business: false)
    factory = business ? :user_compliance_info_business : :user_compliance_info
    create(factory, user:, birthday:, skip_stripe_job_on_create: true)
  end

  # Stripe's answer keyed by account id, so one example can hold different dates per account.
  #
  # Built as a real `Stripe::StripeObject`, not a Hash. The two are not interchangeable here: a
  # StripeObject exposes `[]` but no `dig`, so a Hash stub silently passes code that would raise
  # NoMethodError against every live account.
  def stub_stripe_dobs(by_account_id)
    allow(Stripe::Account).to receive(:retrieve) do |account_id|
      raise Stripe::InvalidRequestError.new("no such account", nil) unless by_account_id.key?(account_id)

      dob = by_account_id[account_id]
      Stripe::StripeObject.construct_from(
        individual: dob && { dob: { year: dob.year, month: dob.month, day: dob.day } }
      )
    end
  end

  def message
    captured = nil
    allow(InternalNotificationWorker).to receive(:perform_async) { |_room, _subject, body| captured = body }
    described_class.new.perform
    captured
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
    $redis.del(RedisKey.stripe_dob_drift_sweep_cursor)
  end

  it "reports a seller whose Stripe date of birth disagrees with ours" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2010, 4, 27))
    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27))

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, subject, body|
      expect(room).to eq("payouts")
      expect(subject).to eq("Stripe date-of-birth drift")
      expect(body).to include("1 seller has a date of birth on Stripe that disagrees with ours")
      expect(body).to include(seller.email)
      expect(body).to include("we hold 2010-04-27, Stripe holds 2005-04-27")
      expect(body).to include(account.charge_processor_merchant_id)
    end
  end

  it "stays silent when the two copies agree" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2005, 4, 27))
    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27))

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # The year is the field that decides whether someone may be paid at all, and the reported cases all
  # matched on day and month — a comparison that only looked at the year, or only at the whole string
  # loosely, would miss or invent drift.
  it "reports a year-only disagreement on an otherwise identical date" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2009, 8, 27))
    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2004, 8, 27))

    expect(message).to include("we hold 2009-08-27, Stripe holds 2004-08-27")
  end

  it "flags a seller our own gate holds as under 18, because that is the money-holding direction" do
    account = gumroad_managed_account
    compliance_info(birthday: 16.years.ago.to_date)
    stub_stripe_dobs(account.charge_processor_merchant_id => 21.years.ago.to_date)

    expect(message).to include("[under 18 on our side — payouts gated]")
  end

  it "does not flag the gate marker for a seller we hold as an adult" do
    account = gumroad_managed_account
    compliance_info(birthday: 30.years.ago.to_date)
    stub_stripe_dobs(account.charge_processor_merchant_id => 25.years.ago.to_date)

    expect(message).not_to include("payouts gated")
  end

  # An absent date on Stripe is a real disagreement with a birthday we hold — that account cannot be
  # verified against anything — so it must not be filtered out with the agreements.
  it "reports an account holding no date of birth at all" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2010, 4, 27))
    stub_stripe_dobs(account.charge_processor_merchant_id => nil)

    expect(message).to include("Stripe holds no date of birth on file")
  end

  # A failed read establishes nothing. Counting it as agreement hides drift; counting it as drift
  # invents it.
  it "counts an unreadable Stripe account separately instead of calling it clear or drifted" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2010, 4, 27))
    allow(Stripe::Account).to receive(:retrieve).with(account.charge_processor_merchant_id)
                                               .and_raise(Stripe::APIConnectionError.new("timeout"))

    body = message
    expect(body).to include("1 more could not be read from Stripe this run")
    expect(body).not_to include(seller.email)
  end

  it "skips a business record, whose date of birth belongs to the representative Stripe syncs separately" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2010, 4, 27), business: true)
    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27))

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "skips a Stripe Connect account, whose legal entity is the seller's own to maintain" do
    create(:merchant_account_stripe_connect, user: seller)
    compliance_info(birthday: Date.new(2010, 4, 27))
    allow(Stripe::Account).to receive(:retrieve).and_return(
      Stripe::StripeObject.construct_from(individual: { dob: { year: 2005, month: 4, day: 27 } })
    )

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "skips a seller with no live compliance record, since there is nothing to compare" do
    account = gumroad_managed_account
    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27))

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ranks the under-18 seller above an adult one, because the gate is already holding their money" do
    adult_seller = create(:user)
    adult_account = gumroad_managed_account(user: adult_seller)
    compliance_info(birthday: 30.years.ago.to_date, user: adult_seller)

    minor_account = gumroad_managed_account
    compliance_info(birthday: 16.years.ago.to_date)

    stub_stripe_dobs(adult_account.charge_processor_merchant_id => 40.years.ago.to_date,
                     minor_account.charge_processor_merchant_id => 21.years.ago.to_date)

    lines = message.lines.select { |line| line.start_with?("•") }
    expect(lines.first).to include(seller.email)
    expect(lines.second).to include(adult_seller.email)
  end

  # Regression pin for the defect the adversarial review round found: the first version read the dob
  # with `account.dig(:individual, :dob)`, which raises NoMethodError on every live account because
  # `Stripe::Account` is a `Stripe::StripeObject` and StripeObject has no `dig`. A Hash stub passed it.
  # This example asserts against the real return type, so a `dig` regression is red rather than green.
  it "reads the date of birth off a real Stripe object, which has no #dig" do
    gumroad_managed_account
    compliance_info(birthday: Date.new(2010, 4, 27))
    stripe_account = Stripe::StripeObject.construct_from(
      individual: { dob: { year: 2005, month: 4, day: 27 } }
    )
    expect(stripe_account).not_to respond_to(:dig)
    allow(Stripe::Account).to receive(:retrieve).and_return(stripe_account)

    expect(message).to include("we hold 2010-04-27, Stripe holds 2005-04-27")
  end

  describe "sweeping the population across runs" do
    it "resumes after the account the previous run compared last" do
      first_account = gumroad_managed_account
      compliance_info(birthday: Date.new(2010, 4, 27))

      second_seller = create(:user)
      second_account = gumroad_managed_account(user: second_seller)
      compliance_info(birthday: Date.new(2009, 8, 27), user: second_seller)

      stub_stripe_dobs(first_account.charge_processor_merchant_id => Date.new(2005, 4, 27),
                       second_account.charge_processor_merchant_id => Date.new(2004, 8, 27))
      stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)

      expect(message).to include(seller.email)
      expect($redis.get(RedisKey.stripe_dob_drift_sweep_cursor).to_i).to eq(first_account.id)

      second_message = message
      expect(second_message).to include(second_seller.email)
      expect(second_message).not_to include(seller.email)
    end

    it "wraps to the start once it runs out of accounts" do
      account = gumroad_managed_account
      compliance_info(birthday: Date.new(2010, 4, 27))
      stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27))
      $redis.set(RedisKey.stripe_dob_drift_sweep_cursor, account.id)

      expect(message).to include(seller.email)
    end
  end

  # A bound that silently decides the report is empty is indistinguishable from a clean platform, so
  # a truncated scan has to send even with nothing to show.
  it "sends a truncated scan that found nothing, so the bound cannot pass for a clean result" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2005, 4, 27))

    other = create(:user)
    other_account = gumroad_managed_account(user: other)
    compliance_info(birthday: Date.new(2005, 4, 27), user: other)

    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27),
                     other_account.charge_processor_merchant_id => Date.new(2005, 4, 27))
    stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)

    body = message
    expect(body).to include("not evidence that none do")
    expect(body).to include("this is a floor")
  end

  it "stays silent when the scan completed and found nothing" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2005, 4, 27))
    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27))

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # Nothing here may write a date of birth: which copy is true is what a drift row leaves open.
  it "tells its reader not to correct either copy from the report" do
    account = gumroad_managed_account
    compliance_info(birthday: Date.new(2010, 4, 27))
    stub_stripe_dobs(account.charge_processor_merchant_id => Date.new(2005, 4, 27))

    expect(message).to include("Do not correct either copy from this report")
  end
end
