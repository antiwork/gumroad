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

      context "when the creator is under enforcement action" do
        context "when suspended for fraud" do
          before do
            @creator.flag_for_fraud!(author_name: "admin", content: "fraud detected")
            @creator.suspend_for_fraud!(author_name: "admin", content: "confirmed fraud")
          end

          it "does not probate the creator" do
            expect do
              @creator.check_for_low_balance_and_probate(@purchase.id)
            end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

            expect(@creator.reload.suspended_for_fraud?).to eq(true)
            expect(@creator.reload.on_probation?).to eq(false)
          end
        end

        context "when suspended for TOS violation" do
          before do
            product = create(:product, user: @creator)
            @creator.flag_for_tos_violation!(author_name: "admin", content: "tos violation", product_id: product.id)
            @creator.suspend_for_tos_violation!(author_name: "admin", content: "confirmed tos violation")
          end

          it "does not probate the creator" do
            expect do
              @creator.check_for_low_balance_and_probate(@purchase.id)
            end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

            expect(@creator.reload.suspended_for_tos_violation?).to eq(true)
            expect(@creator.reload.on_probation?).to eq(false)
          end
        end
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

  describe "#restore_user_risk_state_before_probation!" do
    with_versioning do
      it "reverts to not_reviewed and creates a comment" do
        @creator.send(:disable_refunds_and_put_on_probation!)

        expect { @creator.restore_user_risk_state_before_probation! }
          .to change { @creator.reload.user_risk_state }.from("on_probation").to("not_reviewed")

        comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_NOT_REVIEWED, author_name: "LowBalanceFraudCheck").order(:created_at).last

        expect(comment.author_name).to eq("LowBalanceFraudCheck")
        expect(comment.content).to include("Risk state reverted to \"Not reviewed\" automatically on", "as balance has recovered to $100")
      end

      it "reverts to compliant and creates a comment" do
        @creator.mark_compliant!(author_name: "admin")
        @creator.send(:disable_refunds_and_put_on_probation!)

        expect { @creator.restore_user_risk_state_before_probation! }
          .to change { @creator.reload.user_risk_state }.from("on_probation").to("compliant")
          .and change { @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT).count }.by(1)

        compliant_comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT, author_name: "LowBalanceFraudCheck").order(:created_at).last

        expect(compliant_comment.author_name).to eq("LowBalanceFraudCheck")
        expect(compliant_comment.content).to include("Risk state reverted to \"Compliant\" automatically on", "as balance has recovered to $100")
      end

      context "when previous risk state is invalid" do
        it "raises InvalidRecoveryStateError for flagged_for_fraud, flagged_for_tos_violation, suspended_for_fraud, suspended_for_tos_violation, and newly created states" do
          @creator.flag_for_fraud!(author_name: "admin", content: "fraud detected")
          @creator.send(:disable_refunds_and_put_on_probation!)

          expect { @creator.restore_user_risk_state_before_probation! }
            .to raise_error(User::LowBalanceFraudCheck::InvalidRecoveryStateError, /Invalid previous state for recovery: flagged_for_fraud/)

          @creator.mark_compliant!(author_name: "admin")
          product = create(:product, user: @creator)
          @creator.flag_for_tos_violation!(author_name: "admin", content: "tos violation", product_id: product.id)
          @creator.send(:disable_refunds_and_put_on_probation!)

          expect { @creator.restore_user_risk_state_before_probation! }
            .to raise_error(User::LowBalanceFraudCheck::InvalidRecoveryStateError, /Invalid previous state for recovery: flagged_for_tos_violation/)

          @creator.mark_compliant!(author_name: "admin")
          @creator.flag_for_fraud!(author_name: "admin", content: "fraud detected")
          @creator.suspend_for_fraud!(author_name: "admin", content: "confirmed fraud")
          @creator.put_on_probation!(author_name: "admin", content: "test")
          @creator.disable_refunds!

          expect { @creator.restore_user_risk_state_before_probation! }
            .to raise_error(User::LowBalanceFraudCheck::InvalidRecoveryStateError, /Invalid previous state for recovery: suspended_for_fraud/)

          @creator.mark_compliant!(author_name: "admin")
          product = create(:product, user: @creator)
          @creator.flag_for_tos_violation!(author_name: "admin", content: "tos violation", product_id: product.id)
          @creator.suspend_for_tos_violation!(author_name: "admin", content: "confirmed tos violation")
          @creator.put_on_probation!(author_name: "admin", content: "test")
          @creator.disable_refunds!

          expect { @creator.restore_user_risk_state_before_probation! }
            .to raise_error(User::LowBalanceFraudCheck::InvalidRecoveryStateError, /Invalid previous state for recovery: suspended_for_tos_violation/)

          @creator.send(:disable_refunds_and_put_on_probation!)
          probation_version = @creator.send(:find_latest_probation_paper_trail_version)

          probation_version.update_column(
            :object_changes,
            PaperTrail.serializer.dump({ "user_risk_state" => ["some_new_state", "on_probation"] })
          )

          expect { @creator.restore_user_risk_state_before_probation! }
            .to raise_error(User::LowBalanceFraudCheck::InvalidRecoveryStateError, /Invalid previous state for recovery: some_new_state/)
        end
      end
    end
  end

  describe "#can_recover_from_low_balance_probation?" do
    context "when user is not on probation" do
      it "returns false" do
        expect(@creator.can_recover_from_low_balance_probation?(50_00)).to eq(false)
      end
    end

    context "when user is on probation for low balance and balance is at or above $100" do
      it "returns true" do
        @creator.send(:disable_refunds_and_put_on_probation!)

        expect(@creator.can_recover_from_low_balance_probation?(100_00)).to eq(true)
      end
    end

    context "when user is on probation for low balance but balance is below $100" do
      it "returns false" do
        @creator.update!(user_risk_state: "not_reviewed")
        @creator.send(:disable_refunds_and_put_on_probation!)

        expect(@creator.can_recover_from_low_balance_probation?(99_99)).to eq(false)
      end
    end

    context "when user is on probation but not for low balance" do
      it "returns false" do
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_ON_PROBATION, created_at: 1.month.ago, author_name: "LowBalanceFraudCheck", content: "Probated (payouts suspended) automatically")
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_COMPLIANT, created_at: 1.day.ago, author_name: "LowBalanceFraudCheck", content: "Marked compliant automatically")
        @creator.put_on_probation!(author_name: "pause_payouts_for_seller_based_on_chargeback_rate", content: "Payouts automatically paused due to chargeback rate (50%) exceeding 3% volume.")

        expect(@creator.can_recover_from_low_balance_probation?(100_00)).to eq(false)
      end
    end
  end
end
