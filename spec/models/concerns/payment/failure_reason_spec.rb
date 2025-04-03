# frozen_string_literal: true

require "spec_helper"

describe Payment::FailureReason do
  let(:payment) { create(:payment) }

  describe "#add_payment_failure_reason_comment" do
    context "when failure_reason is not present" do
      it "doesn't add payout note to the user" do
        expect do
          payment.mark_failed!
        end.to_not change { payment.user.comments.count }
      end
    end

    context "when failure_reason is present" do
      context "when processor is PAYPAL" do
        context "when solution is present" do
          it "adds payout note to the user" do
            expect do
              payment.mark_failed!("PAYPAL 11711")
            end.to change { payment.user.comments.count }.by(1)

            payout_note = "Payout via Paypal on #{payment.created_at} failed because per-transaction sending limit exceeded. "
            payout_note += "Solution: Contact PayPal to get receiving limit on the account increased. "
            payout_note += "If that's not possible, Gumroad can split their payout, please contact Gumroad Support."
            expect(payment.user.comments.last.content).to eq payout_note
          end
        end

        context "when solution is not present" do
          it "doesn't add payout note to the user" do
            expect do
              payment.mark_failed!("PAYPAL unknown_failure_reason")
            end.to_not change { payment.user.comments.count }
          end
        end
      end

      context "when processor is Stripe" do
        before do
          payment.update!(processor: PayoutProcessorType::STRIPE)
        end

        context "when solution is present" do
          it "adds payout note to the user" do
            expect do
              payment.mark_failed!("account_closed")
            end.to change { payment.user.comments.count }.by(1)

            payout_note = "Payout via Stripe on #{payment.created_at} failed because the bank account has been closed. "
            payout_note += "Solution: Use another bank account."
            expect(payment.user.comments.last.content).to eq payout_note
          end
        end

        context "when solution is not present" do
          it "doesn't add payout note to the user" do
            expect do
              payment.mark_failed!("unknown_failure_reason")
            end.to_not change { payment.user.comments.count }
          end
        end
      end
    end
  end
end
