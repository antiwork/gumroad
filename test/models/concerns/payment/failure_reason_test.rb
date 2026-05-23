# frozen_string_literal: true

require "test_helper"

class PaymentFailureReasonTest < ActiveSupport::TestCase
  self.described_class = Payment::FailureReason



  context_ Payment::FailureReason do
    let(:payment) { create(:payment) }

  context_ "#add_payment_failure_reason_comment" do
  context_ "when failure_reason is not present" do
  test "doesn't add payout note to the user" do
          expect do
            payment.mark_failed!
          end.not_to change { payment.user.comments.count }
        end
      end

  context_ "when failure_reason is present" do
  context_ "when processor is PAYPAL" do
  context_ "when solution is present" do
  test "adds payout note to the user" do
              expect do
                payment.mark_failed!("PAYPAL 11711")
              end.to change { payment.user.comments.count }.by(1)

              payout_note = "Payout via Paypal on #{payment.created_at} failed because per-transaction sending limit exceeded. "
              payout_note += "Solution: Contact PayPal to get receiving limit on the account increased. "
              payout_note += "If that's not possible, Gumroad can split their payout, please contact Gumroad Support."
              expect(payment.user.comments.last.content).to eq payout_note
            end
          end

  context_ "when solution is not present" do
  test "doesn't add payout note to the user" do
              expect do
                payment.mark_failed!("PAYPAL unknown_failure_reason")
              end.not_to change { payment.user.comments.count }
            end
          end
        end

  context_ "when processor is Stripe" do
          before do
            payment.update!(processor: PayoutProcessorType::STRIPE)
          end

  context_ "when solution is present" do
  test "adds payout note to the user" do
              expect do
                payment.mark_failed!("account_closed")
              end.to change { payment.user.comments.count }.by(1)

              payout_note = "Payout via Stripe on #{payment.created_at} failed because the bank account has been closed. "
              payout_note += "Solution: Use another bank account."
              expect(payment.user.comments.last.content).to eq payout_note
            end
          end

  context_ "when failure reason is bank_account_not_found_at_stripe" do
  test "adds a payout note explaining the bank account needs to be re-added" do
              expect do
                payment.mark_failed!(Payment::FailureReason::BANK_ACCOUNT_NOT_FOUND_AT_STRIPE)
              end.to change { payment.user.comments.count }.by(1)

              payout_note = "Payout via Stripe on #{payment.created_at} failed because the bank account on file at Stripe was replaced, so payouts can no longer be sent to the saved reference. "
              payout_note += "Solution: Re-add the bank account in payout settings to refresh the saved reference."
              expect(payment.user.comments.last.content).to eq payout_note
            end
          end

  context_ "when solution is not present" do
  test "doesn't add payout note to the user" do
              expect do
                payment.mark_failed!("unknown_failure_reason")
              end.not_to change { payment.user.comments.count }
            end
          end
        end
      end
    end
  end
end
