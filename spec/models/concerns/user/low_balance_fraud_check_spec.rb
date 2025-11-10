# frozen_string_literal: true

require "spec_helper"

describe User::LowBalanceFraudCheck do
  before do
    @creator = create(:user)
    @purchase = create(:refunded_purchase, link: create(:product, user: @creator))
  end

  describe "#enable_refunds!" do
    before do
      @creator.refunds_disabled = true
    end

    it "enables refunds for the creator" do
      @creator.enable_refunds!

      expect(@creator.reload.refunds_disabled?).to eq(false)
    end


    it "is called when a creator is marked as compliant" do
      @creator.mark_compliant!(author_name: "test")

      expect(@creator.reload.refunds_disabled?).to eq(false)
    end
  end

  describe "#disable_refunds!" do
    before do
      @creator.refunds_disabled = false
    end

    it "disables refunds for the creator" do
      @creator.disable_refunds!

      expect(@creator.reload.refunds_disabled?).to eq(true)
    end
  end

  describe "#check_for_low_balance_and_probate" do
    context "when the unpaid balance is above threshold" do
      before do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(-40_00)
      end

      it "doesn't probate the creator" do
        @creator.check_for_low_balance_and_probate(@purchase.id)

        expect(@creator.reload.on_probation?).to eq(false)
      end
    end

    context "when the unpaid balance is below threshold" do
      before do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(-200_00)
      end

      context "when the creator is not on probation" do
        context "when the creator is not recently probated for low balance" do
          it "probates the creator" do
            expect do
              @creator.check_for_low_balance_and_probate(@purchase.id)
            end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

            expect(@creator.reload.on_probation?).to eq(true)
            expect(@creator.comments.last.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity")
          end
        end

        context "when the creator is recently probated" do
          context "when creator was probated before LOW_BALANCE_PROBATION_WAIT_TIME" do
            before do
              @creator.send(:disable_refunds_and_put_on_probation!)
              comment = @creator.comments.with_type_on_probation.order(:created_at).last
              comment.update_attribute(:created_at, 3.months.ago)
              @creator.mark_compliant(author_name: "test")
            end

            it "probates the creator" do
              expect do
                @creator.check_for_low_balance_and_probate(@purchase.id)
              end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

              expect(@creator.reload.on_probation?).to eq(true)
              expect(@creator.comments.last.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity")
            end
          end

          context "when creator was probated after LOW_BALANCE_PROBATION_WAIT_TIME" do
            before do
              @creator.send(:disable_refunds_and_put_on_probation!)
              comment = @creator.comments.with_type_on_probation.order(:created_at).last
              comment.update_attribute(:created_at, 1.months.ago)
              @creator.mark_compliant(author_name: "test")
            end

            it "doesn't probate the creator" do
              expect do
                @creator.check_for_low_balance_and_probate(@purchase.id)
              end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

              expect(@creator.reload.on_probation?).to eq(false)
            end
          end
        end
      end
    end
  end

  describe "#mark_compliant_if_balance_recovered!" do
    it "does nothing when user is not on probation" do
      allow(@creator).to receive(:unpaid_balance_cents).and_return(50_00)
      expect { @creator.mark_compliant_if_balance_recovered! }.not_to change { @creator.reload.user_risk_state }
    end

    context "when user is on probation for low balance" do
      before do
        @creator.send(:disable_refunds_and_put_on_probation!)
      end

      it "does nothing when balance is below $100" do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(99_99)
        expect { @creator.mark_compliant_if_balance_recovered! }.not_to change { @creator.reload.user_risk_state }
      end

      it "marks user compliant, creates compliant comment, and enables refunds when balance is at or above $100" do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)
        expect { @creator.mark_compliant_if_balance_recovered! }
          .to change { @creator.reload.user_risk_state }.from("on_probation").to("compliant")

        compliant_comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT).order(created_at: :desc).first
        expect(compliant_comment.author_name).to eq("LowBalanceFraudCheck")
        expect(compliant_comment.content).to include("Marked compliant automatically", "balance has recovered to $100")
        expect(@creator.reload.refunds_disabled?).to eq(false)
      end
    end

    context "when user is on probation but not for low balance" do
      before do
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_ON_PROBATION, author_name: "LowBalanceFraudCheck", content: "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity", created_at: 1.month.ago)
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_COMPLIANT, author_name: "LowBalanceFraudCheck", content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as balance has recovered to $100", created_at: 1.day.ago)
        @creator.put_on_probation!(author_name: "pause_payouts_for_seller_based_on_chargeback_rate", content: "Payouts automatically paused due to chargeback rate (50%) exceeding 3% volume.")
      end

      it "does not mark user as compliant if balance is above $100" do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)
        expect { @creator.mark_compliant_if_balance_recovered! }.not_to change { @creator.reload.user_risk_state }
      end
    end
  end
end
