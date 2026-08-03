# frozen_string_literal: true

require "spec_helper"

describe ReleaseChargebackRatePayoutPauseForSellerJob do
  let(:seller) { create(:user) }

  # The threshold is a policy number that has already moved once (3% to 1%). These specs derive
  # their rates from the constant so that the next move keeps them meaningful: a spec that spells
  # out "1.2% is recovered" silently stops testing recovery the day the limit drops below 1.2%.
  def recovered_rate
    format("%.1f%%", User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS / 2)
  end

  def still_high_rate
    format("%.1f%%", User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS * 4)
  end

  def pause_for_chargeback_rate!(user = seller)
    user.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    user.comments.create!(
      content: "Payouts automatically paused due to chargeback rate (#{still_high_rate}) exceeding #{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume over the last #{User::PAYOUT_CHARGEBACK_RATE_WINDOW.inspect}.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:high_chargeback_rate]
    )
  end

  def stub_rate(volume)
    allow_any_instance_of(User).to receive(:lost_chargebacks_for_payout_gate).and_return({ volume:, count: "0.0%" })
  end

  context "when the rate has recovered" do
    before do
      pause_for_chargeback_rate!
      stub_rate(recovered_rate)
    end

    it "resumes payouts and clears the pause source" do
      described_class.new.perform(seller.id)

      seller.reload
      expect(seller.payouts_paused_internally?).to be(false)
      expect(seller.payouts_paused_by_source).to be_nil
    end

    it "leaves an audit comment naming the rate it released at" do
      described_class.new.perform(seller.id)

      comment = seller.comments.with_type_payouts_resumed.last
      expect(comment.author_name).to eq(User::CHARGEBACK_RATE_PAYOUT_RESUME_COMMENT_AUTHOR)
      expect(comment.content).to include(recovered_rate)
    end

    it "does nothing on a second run once the hold is gone" do
      described_class.new.perform(seller.id)

      expect do
        described_class.new.perform(seller.id)
      end.to_not change { seller.reload.comments.count }
    end
  end

  it "keeps the hold when the rate is still above the limit" do
    pause_for_chargeback_rate!
    stub_rate(still_high_rate)

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  # The pause only fires when the rate is strictly above the limit, so an account sitting exactly
  # at the limit is one the pause would never have created — the release has to mirror that.
  it "releases when the rate is exactly at the limit" do
    pause_for_chargeback_rate!
    stub_rate("#{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}%")

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(false)
  end

  it "keeps the hold when there is no rate to compare" do
    pause_for_chargeback_rate!
    stub_rate("NA")

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  it "leaves suspended sellers alone" do
    pause_for_chargeback_rate!
    stub_rate("0.5%")
    seller.update!(user_risk_state: "suspended_for_fraud")

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  it "leaves flagged sellers alone" do
    pause_for_chargeback_rate!
    stub_rate("0.5%")
    seller.update!(user_risk_state: "flagged_for_fraud")

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  it "does not touch an admin pause" do
    stub_rate("0.5%")
    seller.update!(payouts_paused_internally: true, payouts_paused_by: create(:user).id)

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  it "does not touch a repeated-failed-payouts pause" do
    stub_rate("0.5%")
    seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    seller.comments.create!(
      content: "Payouts paused automatically after 3 consecutive failed payouts.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
    )

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  it "does not touch a seller re-paused for failed payouts after an earlier chargeback pause" do
    stub_rate("0.5%")
    pause_for_chargeback_rate!
    seller.comments.create!(
      content: "Payouts paused automatically after 3 consecutive failed payouts.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
    )

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  it "does not touch a seller-initiated pause" do
    stub_rate("0.5%")
    seller.update!(payouts_paused_by_user: true)

    described_class.new.perform(seller.id)

    seller.reload
    expect(seller.payouts_paused_by_user?).to be(true)
    expect(seller.payouts_paused_internally?).to be(false)
    expect(seller.comments.with_type_payouts_resumed).to be_empty
  end

  it "lifts the hold but says so plainly when the seller has also paused their own payouts" do
    pause_for_chargeback_rate!
    seller.update!(payouts_paused_by_user: true)
    stub_rate("0.5%")

    described_class.new.perform(seller.id)

    seller.reload
    expect(seller.payouts_paused_internally?).to be(false)
    expect(seller.payouts_paused_by_user?).to be(true)
    expect(seller.comments.with_type_payouts_resumed.last.content)
      .to include("Payouts remain paused by the creator")
  end

  it "leaves a closed account alone even though closing it also pauses payouts" do
    pause_for_chargeback_rate!
    stub_rate("0.5%")
    seller.update!(deleted_at: Time.current)

    described_class.new.perform(seller.id)

    seller.reload
    expect(seller.payouts_paused_internally?).to be(true)
    expect(seller.comments.with_type_payouts_resumed).to be_empty
  end

  it "ignores a deleted pause comment when deciding what the current hold is" do
    stub_rate("0.5%")
    pause_for_chargeback_rate!.mark_deleted!
    seller.comments.create!(
      content: "Payouts paused automatically after 3 consecutive failed payouts.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
    )

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  # A retracted failed-payouts note does NOT re-expose the older chargeback hold: the predicate
  # reads deleted comments too, on purpose, so deleting a comment can never widen what this job
  # releases. See User#payouts_paused_for_chargeback_rate?.
  it "keeps the hold when a newer pause comment from the other check has been deleted" do
    stub_rate("0.5%")
    pause_for_chargeback_rate!
    seller.comments.create!(
      content: "Payouts paused automatically after 3 consecutive failed payouts.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: User::SYSTEM_PAYOUT_PAUSE_COMMENT_AUTHORS[:repeated_failed_payouts]
    ).mark_deleted!

    described_class.new.perform(seller.id)

    expect(seller.reload.payouts_paused_internally?).to be(true)
  end

  it "does not release a hold an admin re-applied while the rate was being computed" do
    pause_for_chargeback_rate!
    admin_id = create(:user).id
    # The rate lookup is the slow part; simulate an admin pausing the account during it.
    allow_any_instance_of(User).to receive(:lost_chargebacks_for_payout_gate) do
      seller.update!(payouts_paused_internally: true, payouts_paused_by: admin_id)
      { volume: "0.5%", count: "0.0%" }
    end

    described_class.new.perform(seller.id)

    seller.reload
    expect(seller.payouts_paused_internally?).to be(true)
    expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
    expect(seller.comments.with_type_payouts_resumed).to be_empty
  end

  it "does nothing when the user no longer exists" do
    stub_rate("0.5%")

    expect { described_class.new.perform(User.maximum(:id).to_i + 1) }.to_not raise_error
  end
end
