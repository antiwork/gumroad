# frozen_string_literal: true

require "spec_helper"

describe User::LowBalanceFraudCheck do
  before do
    @creator = create(:user)
    @purchase = create(:refunded_purchase, link: create(:product, user: @creator))
  end

  def create_probation_version_for_state(user, previous_state)
    PaperTrail::Version.create!(
      item_type: "User",
      item_id: user.id,
      event: "update",
      object_changes: PaperTrail.serializer.dump({ "user_risk_state" => [previous_state, "on_probation"] }),
      created_at: Time.current
    )
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
        probation_version = @creator.send(:find_latest_probation_paper_trail_version)

        expect(@creator).to receive(:find_previous_comment_content_for_state)
          .with(Comment::COMMENT_TYPE_NOTE, probation_version)
          .and_call_original

        expect { @creator.restore_user_risk_state_before_probation! }
          .to change { @creator.reload.user_risk_state }.from("on_probation").to("not_reviewed")

        comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_NOTE, author_name: "LowBalanceFraudCheck").order(created_at: :desc).first

        expect(comment.author_name).to eq("LowBalanceFraudCheck")
        expect(comment.content).to include("Risk state reverted automatically on", "as balance has recovered to $100")
      end

      it "reverts to compliant and creates a comment" do
        @creator.mark_compliant!(author_name: "admin")
        @creator.send(:disable_refunds_and_put_on_probation!)
        probation_version = @creator.send(:find_latest_probation_paper_trail_version)

        expect(@creator).to receive(:find_previous_comment_content_for_state)
          .with(Comment::COMMENT_TYPE_COMPLIANT, probation_version)
          .and_call_original

        expect { @creator.restore_user_risk_state_before_probation! }
          .to change { @creator.reload.user_risk_state }.from("on_probation").to("compliant")
          .and change { @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT).count }.by(1)

        compliant_comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT, author_name: "LowBalanceFraudCheck").order(created_at: :desc).first

        expect(compliant_comment.author_name).to eq("LowBalanceFraudCheck")
        expect(compliant_comment.content).to include("Risk state reverted automatically on", "as balance has recovered to $100")
      end

      it "reverts to flagged_for_fraud and creates a comment" do
        @creator.flag_for_fraud!(author_name: "admin", content: "fraud detected")
        @creator.send(:disable_refunds_and_put_on_probation!)
        probation_version = @creator.send(:find_latest_probation_paper_trail_version)

        expect(@creator).to receive(:find_previous_comment_content_for_state)
          .with(Comment::COMMENT_TYPE_FLAGGED, probation_version)
          .and_call_original

        expect { @creator.restore_user_risk_state_before_probation! }
          .to change { @creator.reload.user_risk_state }.from("on_probation").to("flagged_for_fraud")

        comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_FLAGGED, author_name: "LowBalanceFraudCheck").order(created_at: :desc).first

        expect(comment.author_name).to eq("LowBalanceFraudCheck")
        expect(comment.content).to include("Risk state reverted automatically on", "as balance has recovered to $100")
      end

      context "when user was previously flagged_for_tos_violation" do
        context "when it was a bulk flag" do
          it "reverts to flagged_for_tos_violation with bulk flag and creates a comment" do
            @creator.flag_for_tos_violation!(author_name: "Admin", bulk: true)
            @creator.send(:disable_refunds_and_put_on_probation!)
            probation_version = @creator.send(:find_latest_probation_paper_trail_version)

            expect(@creator).to receive(:find_previous_comment_content_for_state)
              .with(Comment::COMMENT_TYPE_FLAGGED, probation_version)
              .and_call_original

            expect { @creator.restore_user_risk_state_before_probation! }
              .to change { @creator.reload.user_risk_state }.from("on_probation").to("flagged_for_tos_violation")

            comment = @creator.comments
              .where(comment_type: Comment::COMMENT_TYPE_FLAGGED, author_name: "LowBalanceFraudCheck")
              .order(created_at: :desc)
              .first

            expect(comment.author_name).to eq("LowBalanceFraudCheck")
            expect(comment.content).to include("Risk state reverted automatically on", "as balance has recovered to $100")
          end
        end

        context "when it was an individual flag with a product" do
          let(:product) { create(:product, user: @creator) }

          it "reverts to flagged_for_tos_violation and creates a comment" do
            @creator.flag_for_tos_violation!(author_name: "Admin", product_id: product.id)
            @creator.send(:disable_refunds_and_put_on_probation!)
            probation_version = @creator.send(:find_latest_probation_paper_trail_version)

            expect(@creator).to receive(:find_previous_comment_content_for_state)
              .with(Comment::COMMENT_TYPE_FLAGGED, probation_version)
              .and_call_original

            expect { @creator.restore_user_risk_state_before_probation! }
              .to change { @creator.reload.user_risk_state }.from("on_probation").to("flagged_for_tos_violation")

            comment = @creator.comments
              .where(comment_type: Comment::COMMENT_TYPE_FLAGGED, author_name: "LowBalanceFraudCheck")
              .order(created_at: :desc)
              .first

            expect(comment.author_name).to eq("LowBalanceFraudCheck")
            expect(comment.content).to include("Risk state reverted automatically on", "as balance has recovered to $100")
          end
        end
      end

      context "when previous risk state is invalid" do
        it "raises InvalidRecoveryStateError for suspended_for_fraud, suspended_for_tos_violation, and newly created states" do
          @creator.flag_for_fraud!(author_name: "admin", content: "fraud detected")
          @creator.suspend_for_fraud!(author_name: "admin", content: "confirmed fraud")
          @creator.update_column(:user_risk_state, "on_probation")
          @creator.disable_refunds!

          create_probation_version_for_state(@creator, "suspended_for_fraud")

          expect { @creator.restore_user_risk_state_before_probation! }
            .to raise_error(User::LowBalanceFraudCheck::InvalidRecoveryStateError, /Invalid previous state for recovery: suspended_for_fraud/)

          product = create(:product, user: @creator)
          @creator.flag_for_tos_violation!(author_name: "admin", content: "tos violation", product_id: product.id)
          @creator.suspend_for_tos_violation!(author_name: "admin", content: "confirmed tos violation")
          @creator.update_column(:user_risk_state, "on_probation")

          create_probation_version_for_state(@creator, "suspended_for_tos_violation")

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
    context "returns true" do
      it "when user is on probation for low balance and balance is at or above $100" do
        @creator.update!(user_risk_state: "not_reviewed")
        @creator.send(:disable_refunds_and_put_on_probation!)
        allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)

        expect(@creator.can_recover_from_low_balance_probation?).to eq(true)
      end
    end

    context "returns false" do
      it "when user is not on probation" do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(50_00)

        expect(@creator.can_recover_from_low_balance_probation?).to eq(false)
      end

      it "when user is on probation for low balance but balance is below $100" do
        @creator.update!(user_risk_state: "not_reviewed")
        @creator.send(:disable_refunds_and_put_on_probation!)
        allow(@creator).to receive(:unpaid_balance_cents).and_return(99_99)

        expect(@creator.can_recover_from_low_balance_probation?).to eq(false)
      end

      it "when user is on probation but not for low balance" do
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_ON_PROBATION, author_name: "LowBalanceFraudCheck", content: "Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity", created_at: 1.month.ago)
        @creator.comments.create!(comment_type: Comment::COMMENT_TYPE_COMPLIANT, author_name: "LowBalanceFraudCheck", content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as balance has recovered to $100", created_at: 1.day.ago)
        @creator.put_on_probation!(author_name: "pause_payouts_for_seller_based_on_chargeback_rate", content: "Payouts automatically paused due to chargeback rate (50%) exceeding 3% volume.")

        allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)

        expect(@creator.can_recover_from_low_balance_probation?).to eq(false)
      end
    end
  end

  describe "#find_previous_comment_content_for_state" do
    with_versioning do
      it "returns the most recent comment content for the given comment type before the probation version" do
        @creator.mark_compliant!(author_name: "admin")
        compliant_comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT).first
        compliant_comment.update_column(:created_at, 2.days.ago)

        @creator.send(:disable_refunds_and_put_on_probation!)
        probation_version = @creator.send(:find_latest_probation_paper_trail_version)

        result = @creator.find_previous_comment_content_for_state(Comment::COMMENT_TYPE_COMPLIANT, probation_version)

        expect(result).to eq(compliant_comment.content)
      end

      it "returns 'Not Reviewed' when no previous comment exists" do
        @creator.send(:disable_refunds_and_put_on_probation!)
        probation_version = @creator.send(:find_latest_probation_paper_trail_version)

        result = @creator.find_previous_comment_content_for_state(Comment::COMMENT_TYPE_NOTE, probation_version)

        expect(result).to eq("Not Reviewed")
      end

      it "only returns comments created before or at the probation version timestamp" do
        @creator.mark_compliant!(author_name: "admin")
        old_comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT).first
        old_comment.update_column(:created_at, 2.days.ago)

        @creator.send(:disable_refunds_and_put_on_probation!)
        probation_version = @creator.send(:find_latest_probation_paper_trail_version)
        probation_timestamp = probation_version.created_at

        travel_to(probation_timestamp + 1.day) do
          @creator.mark_compliant!(author_name: "admin")
        end
        new_comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_COMPLIANT).order(created_at: :desc).first

        result = @creator.find_previous_comment_content_for_state(Comment::COMMENT_TYPE_COMPLIANT, probation_version)

        expect(result).to eq(old_comment.content)
        expect(new_comment.created_at).to be > probation_timestamp
        expect(result).not_to eq(new_comment.content)
      end
    end
  end
end
