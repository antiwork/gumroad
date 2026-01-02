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

  describe "#mark_not_reviewed!" do
    context "when user is on probation" do
      before do
        @creator.put_on_probation(author_name: "admin", content: "test probation")
      end

      it "transitions from on_probation to not_reviewed" do
        @creator.mark_not_reviewed!(author_name: "LowBalanceFraudCheck", content: "auto removed")

        expect(@creator.reload.user_risk_state).to eq("not_reviewed")
      end

      it "creates a comment with compliant comment_type" do
        @creator.mark_not_reviewed!(author_name: "LowBalanceFraudCheck", content: "auto removed")

        comment = @creator.comments.order(id: :desc).first
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_COMPLIANT)
        expect(comment.content).to eq("auto removed")
      end
    end

    context "when user is not on probation" do
      it "raises an error when transitioning from not_reviewed" do
        expect(@creator.user_risk_state).to eq("not_reviewed")

        expect do
          @creator.mark_not_reviewed!(author_name: "test", content: "test")
        end.to raise_error(StateMachines::InvalidTransition)
      end

      it "raises an error when transitioning from compliant" do
        @creator.mark_compliant!(author_name: "admin", content: "test")

        expect do
          @creator.mark_not_reviewed!(author_name: "test", content: "test")
        end.to raise_error(StateMachines::InvalidTransition)
      end
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

  describe "#check_for_high_balance_and_remove_low_balance_probation!", versioning: true do
    context "when user is on LowBalanceFraudCheck probation" do
      before do
        @creator.send(:disable_refunds_and_put_on_probation!)
        @creator.reload
      end

      context "when balance exceeds $100" do
        before do
          allow(@creator).to receive(:unpaid_balance_cents).and_return(101_00)
        end

        it "reverts to not_reviewed when previous state was not_reviewed" do
          @creator.check_for_high_balance_and_remove_low_balance_probation!

          expect(@creator.reload.user_risk_state).to eq("not_reviewed")
          expect(@creator.refunds_disabled?).to eq(false)
        end

        it "reverts to compliant when previous state was compliant" do
          # Start fresh to get a clean version history
          creator = create(:user)
          creator.mark_compliant!(author_name: "admin", content: "cleared")
          creator.send(:disable_refunds_and_put_on_probation!)
          creator.reload
          allow(creator).to receive(:unpaid_balance_cents).and_return(101_00)

          creator.check_for_high_balance_and_remove_low_balance_probation!

          expect(creator.reload.user_risk_state).to eq("compliant")
          expect(creator.refunds_disabled?).to eq(false)
        end

        it "creates a comment explaining the removal" do
          @creator.check_for_high_balance_and_remove_low_balance_probation!

          latest_comment = @creator.reload.comments.order(id: :desc).first
          expect(latest_comment.content).to eq("Probation removed automatically on #{Time.current.to_fs(:formatted_date_full_month)} because balance exceeded $100")
        end

        it "enables refunds" do
          @creator.check_for_high_balance_and_remove_low_balance_probation!

          expect(@creator.reload.refunds_disabled?).to eq(false)
        end
      end

      context "when balance is exactly $100" do
        before do
          allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)
        end

        it "does not remove probation" do
          @creator.check_for_high_balance_and_remove_low_balance_probation!

          expect(@creator.reload.on_probation?).to eq(true)
        end
      end

      context "when balance is below $100" do
        before do
          allow(@creator).to receive(:unpaid_balance_cents).and_return(50_00)
        end

        it "does not remove probation" do
          @creator.check_for_high_balance_and_remove_low_balance_probation!

          expect(@creator.reload.on_probation?).to eq(true)
        end
      end
    end

    context "when user is manually probated by admin" do
      before do
        @creator.put_on_probation(author_name: "admin", content: "manual probation")
        allow(@creator).to receive(:unpaid_balance_cents).and_return(101_00)
      end

      it "does not remove probation" do
        @creator.check_for_high_balance_and_remove_low_balance_probation!

        expect(@creator.reload.on_probation?).to eq(true)
      end
    end

    context "when user was flagged_for_fraud before probation" do
      before do
        @creator.flag_for_fraud!(author_name: "admin", content: "fraud investigation")
        @creator.send(:disable_refunds_and_put_on_probation!)
        @creator.reload
        allow(@creator).to receive(:unpaid_balance_cents).and_return(101_00)
      end

      it "does not remove probation because admin flagged them" do
        @creator.check_for_high_balance_and_remove_low_balance_probation!

        expect(@creator.reload.on_probation?).to eq(true)
      end
    end

    context "when user was flagged_for_tos_violation before probation" do
      before do
        product = create(:product, user: @creator)
        @creator.flag_for_tos_violation!(author_name: "admin", content: "tos investigation", product_id: product.id)
        @creator.send(:disable_refunds_and_put_on_probation!)
        @creator.reload
        allow(@creator).to receive(:unpaid_balance_cents).and_return(101_00)
      end

      it "does not remove probation because admin flagged them" do
        @creator.check_for_high_balance_and_remove_low_balance_probation!

        expect(@creator.reload.on_probation?).to eq(true)
      end
    end

    context "when user has a newer state transition after LowBalanceFraudCheck probation" do
      before do
        @creator.send(:disable_refunds_and_put_on_probation!)
        # Admin reviews and clears the user
        @creator.mark_compliant!(author_name: "admin", content: "reviewed and cleared")
        # Then admin probates again for a different reason
        @creator.put_on_probation(author_name: "admin", content: "probated again manually")
        allow(@creator).to receive(:unpaid_balance_cents).and_return(101_00)
      end

      it "does not remove probation because admin took action after the auto-probation" do
        @creator.check_for_high_balance_and_remove_low_balance_probation!

        expect(@creator.reload.on_probation?).to eq(true)
      end
    end

    context "when user is not on probation" do
      before do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(101_00)
      end

      it "does nothing" do
        expect(@creator.on_probation?).to eq(false)

        @creator.check_for_high_balance_and_remove_low_balance_probation!

        expect(@creator.reload.user_risk_state).to eq("not_reviewed")
      end
    end
  end

  describe "#previous_risk_state_from_paper_trail", versioning: true do
    it "returns the previous state before probation from PaperTrail" do
      creator = create(:user)
      expect(creator.user_risk_state).to eq("not_reviewed")
      creator.send(:disable_refunds_and_put_on_probation!)

      previous_state = creator.send(:previous_risk_state_from_paper_trail)

      expect(previous_state).to eq("not_reviewed")
    end

    it "returns compliant when user was compliant before probation" do
      creator = create(:user)
      creator.mark_compliant!(author_name: "admin", content: "cleared")
      creator.send(:disable_refunds_and_put_on_probation!)

      previous_state = creator.send(:previous_risk_state_from_paper_trail)

      expect(previous_state).to eq("compliant")
    end

    it "returns compliant when no probation version is found" do
      creator = create(:user)

      previous_state = creator.send(:previous_risk_state_from_paper_trail)

      expect(previous_state).to eq("compliant")
    end
  end
end
