# frozen_string_literal: true

require "test_helper"

class UserLowBalanceFraudCheckTest < ActiveSupport::TestCase
  self.described_class = User::LowBalanceFraudCheck



  context_ User::LowBalanceFraudCheck do
    before do
      @creator = create(:user)
      @purchase = create(:refunded_purchase, link: create(:product, user: @creator))
    end

  context_ "#enable_refunds!" do
      before do
        @creator.refunds_disabled = true
      end

  test "enables refunds for the creator" do
        @creator.enable_refunds!

        expect(@creator.reload.refunds_disabled?).to eq(false)
      end


  test "is called when a creator is marked as compliant" do
        @creator.mark_compliant!(author_name: "test")

        expect(@creator.reload.refunds_disabled?).to eq(false)
      end
    end

  context_ "#disable_refunds!" do
      before do
        @creator.refunds_disabled = false
      end

  test "disables refunds for the creator" do
        @creator.disable_refunds!

        expect(@creator.reload.refunds_disabled?).to eq(true)
      end
    end

  context_ "#check_for_low_balance_and_probate" do
  context_ "when the unpaid balance is above threshold" do
        before do
          allow(@creator).to receive(:unpaid_balance_cents).and_return(-40_00)
        end

  test "doesn't probate the creator" do
          @creator.check_for_low_balance_and_probate(@purchase.id)

          expect(@creator.reload.on_probation?).to eq(false)
        end
      end

  context_ "when the unpaid balance is below threshold" do
        before do
          allow(@creator).to receive(:unpaid_balance_cents).and_return(-200_00)
        end

  context_ "when the creator is under enforcement action" do
  context_ "when suspended for fraud" do
            before do
              @creator.flag_for_fraud!(author_name: "admin", content: "fraud detected")
              @creator.suspend_for_fraud!(author_name: "admin", content: "confirmed fraud")
            end

  test "does not probate the creator" do
              expect do
                @creator.check_for_low_balance_and_probate(@purchase.id)
              end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

              expect(@creator.reload.suspended_for_fraud?).to eq(true)
              expect(@creator.reload.on_probation?).to eq(false)
            end
          end

  context_ "when suspended for TOS violation" do
            before do
              product = create(:product, user: @creator)
              @creator.flag_for_tos_violation!(author_name: "admin", content: "tos violation", product_id: product.id)
              @creator.suspend_for_tos_violation!(author_name: "admin", content: "confirmed tos violation")
            end

  test "does not probate the creator" do
              expect do
                @creator.check_for_low_balance_and_probate(@purchase.id)
              end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

              expect(@creator.reload.suspended_for_tos_violation?).to eq(true)
              expect(@creator.reload.on_probation?).to eq(false)
            end
          end
        end

  context_ "when the creator is not on probation" do
  context_ "when the creator is not recently probated for low balance" do
  test "probates the creator" do
              expect do
                @creator.check_for_low_balance_and_probate(@purchase.id)
              end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

              expect(@creator.reload.on_probation?).to eq(true)
              expect(@creator.comments.last.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity")
            end
          end

  context_ "when the creator is recently probated" do
  context_ "when creator was probated before LOW_BALANCE_PROBATION_WAIT_TIME" do
              before do
                @creator.send(:disable_refunds_and_put_on_probation!)
                comment = @creator.comments.with_type_on_probation.order(:created_at).last
                comment.update_attribute(:created_at, 3.months.ago)
                @creator.mark_compliant(author_name: "test")
              end

  test "probates the creator" do
                expect do
                  @creator.check_for_low_balance_and_probate(@purchase.id)
                end.to have_enqueued_mail(AdminMailer, :low_balance_notify).with(@creator.id, @purchase.id)

                expect(@creator.reload.on_probation?).to eq(true)
                expect(@creator.comments.last.content).to eq("Probated (payouts suspended) automatically on #{Time.current.to_fs(:formatted_date_full_month)} because of suspicious refund activity")
              end
            end

  context_ "when creator was probated after LOW_BALANCE_PROBATION_WAIT_TIME" do
              before do
                @creator.send(:disable_refunds_and_put_on_probation!)
                comment = @creator.comments.with_type_on_probation.order(:created_at).last
                comment.update_attribute(:created_at, 1.months.ago)
                @creator.mark_compliant(author_name: "test")
              end

  test "doesn't probate the creator" do
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

  context_ "#check_for_high_balance_and_remove_low_balance_probation!", versioning: true do
      before do
        allow(@creator).to receive(:unpaid_balance_cents).and_return(100_00)
      end

  context_ "when the user is not on probation" do
  test "does nothing" do
          expect { @creator.check_for_high_balance_and_remove_low_balance_probation! }
            .not_to change { @creator.reload.user_risk_state }
        end
      end

  context_ "when the user is on probation but not by LowBalanceFraudCheck" do
        before do
          @creator.put_on_probation(author_name: "admin", content: "manual")
        end

  test "does nothing" do
          expect { @creator.check_for_high_balance_and_remove_low_balance_probation! }
            .not_to change { @creator.reload.user_risk_state }
        end
      end

  context_ "when the user was put on probation by LowBalanceFraudCheck" do
        before do
          @creator.send(:disable_refunds_and_put_on_probation!)
        end

  test "reverts to not_reviewed when the previous state was not_reviewed" do
          expect(@creator.reload.user_risk_state).to eq("on_probation")

          expect { @creator.check_for_high_balance_and_remove_low_balance_probation! }
            .to change { @creator.reload.user_risk_state }.from("on_probation").to("not_reviewed")

          comment = @creator.comments.where(comment_type: Comment::COMMENT_TYPE_NOT_REVIEWED, author_name: "LowBalanceFraudCheck").order(:created_at).last
          expect(comment).to be_present
        end

  test "reverts to compliant when the previous state was compliant" do
          creator = create(:user)
          allow(creator).to receive(:unpaid_balance_cents).and_return(100_00)

          creator.mark_compliant!(author_name: "test")
          creator.send(:disable_refunds_and_put_on_probation!)

          expect { creator.check_for_high_balance_and_remove_low_balance_probation! }
            .to change { creator.reload.user_risk_state }.from("on_probation").to("compliant")
        end

  test "does not override a newer admin risk-state transition after probation" do
          @creator.mark_compliant!(author_name: "admin", content: "manual review")

          expect { @creator.check_for_high_balance_and_remove_low_balance_probation! }
            .not_to change { @creator.reload.user_risk_state }
        end
      end
    end
  end
end
