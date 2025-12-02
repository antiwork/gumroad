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

    context "when the creator is suspended" do
      before do
        @creator.update!(user_risk_state: "suspended_for_fraud")
        allow(@creator).to receive(:unpaid_balance_cents).and_return(-200_00)
      end

      it "doesn't probate the creator even with low balance" do
        expect do
          @creator.check_for_low_balance_and_probate(@purchase.id)
        end.not_to have_enqueued_mail(AdminMailer, :low_balance_notify)

        expect(@creator.reload.on_probation?).to eq(false)
        expect(@creator.reload.suspended_for_fraud?).to eq(true)
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

  describe "#restore_risk_state_if_balance_recovered!" do
    it "does nothing when user is not on probation" do
      allow(@creator).to receive(:unpaid_balance_cents).and_return(50_00)
      expect { @creator.restore_risk_state_if_balance_recovered! }.not_to change { @creator.reload.user_risk_state }
    end

    context "when user is on probation for low balance" do
      with_versioning do
        it "does nothing when balance is below $100" do
          @creator.update!(user_risk_state: "not_reviewed")
          @creator.send(:disable_refunds_and_put_on_probation!)
          allow(@creator).to receive(:unpaid_balance_cents).and_return(99_99)
          expect { @creator.restore_risk_state_if_balance_recovered! }.not_to change { @creator.reload.user_risk_state }
        end

        context "when balance is at or above $100" do
          before do
            allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)
          end

          context "when user was previously compliant" do
            it "marks user compliant and creates compliant comment" do
              @creator.update!(user_risk_state: "compliant")
              @creator.send(:disable_refunds_and_put_on_probation!)

              expect { @creator.restore_risk_state_if_balance_recovered! }
                .to change { @creator.reload.user_risk_state }.from("on_probation").to("compliant")

              compliant_comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT).order(created_at: :desc).first

              expect(compliant_comment.author_name).to eq("LowBalanceFraudCheck")
              expect(compliant_comment.content).to include("Risk state reverted to \"Compliant\" automatically", "balance has recovered to $100")
              expect(@creator.reload.refunds_disabled?).to eq(false)
            end
          end

          context "when user was previously not_reviewed" do
            it "reverts to not_reviewed and creates a comment" do
              @creator.update!(user_risk_state: "not_reviewed")
              @creator.send(:disable_refunds_and_put_on_probation!)

              expect { @creator.restore_risk_state_if_balance_recovered! }
                .to change { @creator.reload.user_risk_state }.from("on_probation").to("not_reviewed")

              comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_NOTE).order(created_at: :desc).first
              expect(comment.author_name).to eq("LowBalanceFraudCheck")
              expect(comment.content).to include("Risk state reverted to \"Not reviewed\" automatically", "balance has recovered to $100")
            end
          end

          context "when user was previously flagged_for_fraud" do
            it "reverts to flagged_for_fraud and creates a comment" do
              @creator.update!(user_risk_state: "not_reviewed")
              @creator.update!(user_risk_state: "flagged_for_fraud")
              @creator.send(:disable_refunds_and_put_on_probation!)

              expect { @creator.restore_risk_state_if_balance_recovered! }
                .to change { @creator.reload.user_risk_state }.from("on_probation").to("flagged_for_fraud")

              comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_FLAGGED).order(created_at: :desc).first
              expect(comment.author_name).to eq("LowBalanceFraudCheck")
              expect(comment.content).to include("Risk state reverted to \"Flagged for fraud\" automatically", "balance has recovered to $100")
            end
          end

          context "when user was previously flagged_for_tos_violation" do
            context "when it was a bulk flag" do
              it "reverts to flagged_for_tos_violation with bulk flag and creates a comment" do
                @creator.update!(user_risk_state: "not_reviewed")
                @creator.flag_for_tos_violation!(author_name: "Admin", bulk: true)
                @creator.send(:disable_refunds_and_put_on_probation!)

                expect { @creator.restore_risk_state_if_balance_recovered! }
                  .to change { @creator.reload.user_risk_state }.from("on_probation").to("flagged_for_tos_violation")

                comment = @creator.comments
                  .where(comment_type: Comment::COMMENT_TYPE_FLAGGED, author_name: "LowBalanceFraudCheck")
                  .order(created_at: :desc)
                  .first
                expect(comment).to be_present
                expect(comment.content).to include("Risk state reverted to \"Flagged for tos violation\" automatically", "balance has recovered to $100")
              end
            end

            context "when it was an individual flag with a product" do
              let(:product) { create(:product, user: @creator) }

              it "reverts to flagged_for_tos_violation and creates a comment" do
                @creator.update!(user_risk_state: "not_reviewed")
                @creator.flag_for_tos_violation!(author_name: "Admin", product_id: product.id)
                @creator.send(:disable_refunds_and_put_on_probation!)

                expect { @creator.restore_risk_state_if_balance_recovered! }
                  .to change { @creator.reload.user_risk_state }.from("on_probation").to("flagged_for_tos_violation")

                comment = @creator.comments
                  .where(comment_type: Comment::COMMENT_TYPE_FLAGGED, author_name: "LowBalanceFraudCheck")
                  .order(created_at: :desc)
                  .first
                expect(comment).to be_present
                expect(comment.content).to include("Risk state reverted to \"Flagged for tos violation\" automatically", "balance has recovered to $100")
              end
            end
          end
        end
      end
    end

    context "when user is on probation but not for low balance" do
      it "does not restore risk state if balance is above $100" do
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_ON_PROBATION, author_name: "LowBalanceFraudCheck", content: "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity", created_at: 1.month.ago)
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_COMPLIANT, author_name: "LowBalanceFraudCheck", content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as balance has recovered to $100", created_at: 1.day.ago)
        @creator.put_on_probation!(author_name: "pause_payouts_for_seller_based_on_chargeback_rate", content: "Payouts automatically paused due to chargeback rate (50%) exceeding 3% volume.")

        allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)
        expect { @creator.restore_risk_state_if_balance_recovered! }.not_to change { @creator.reload.user_risk_state }
      end
    end
  end

end
