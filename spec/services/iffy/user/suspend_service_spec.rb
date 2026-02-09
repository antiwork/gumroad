# frozen_string_literal: true

require "spec_helper"

describe Iffy::User::SuspendService do
  describe "#perform" do
    let(:user) { create(:user) }
    let(:service) { described_class.new(user.external_id) }

    context "when the user cannot be flagged for TOS violation" do
      before do
        allow_any_instance_of(User).to receive(:can_flag_for_tos_violation?).and_return(false)
      end

      it "does not flag the user" do
        service.perform

        user.reload
        expect(user.tos_violation_reason).to be_nil
        expect(user.flagged?).to be(false)
      end
    end

    context "when the user can be flagged" do
      before do
        allow_any_instance_of(User).to receive(:can_flag_for_tos_violation?).and_return(true)
      end

      it "flags the user and adds a comment" do
        expect_any_instance_of(User).to receive(:flag_for_tos_violation!).with(
          author_name: "Iffy",
          content: "Suspended for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} (General non-compliance)",
          bulk: true
        ).and_call_original

        expect do
          service.perform
        end.to change { user.reload.user_risk_state }.from("not_reviewed").to("flagged_for_tos_violation")

        expect(user.tos_violation_reason).to eq("General non-compliance")
      end
    end
  end
end
