# frozen_string_literal: true

require "spec_helper"

describe Iffy::User::BanService do
  describe "#perform" do
    let(:user) { create(:user) }
    let(:service) { described_class.new(user.external_id) }

    context "when the user can be suspended" do
      it "suspends the user and adds a comment" do
        expect_any_instance_of(User).to receive(:flag_for_tos_violation!).with(
          author_name: "Iffy",
          content: "Banned for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} (General non-compliance)",
          bulk: true
        ).and_call_original
        expect_any_instance_of(User).to receive(:suspend_for_tos_violation!).with(
          author_name: "Iffy",
          content: "Banned for a policy violation on #{Time.current.to_fs(:formatted_date_full_month)} (General non-compliance)",
          bulk: true
        ).and_call_original

        expect do
          service.perform
        end.to change { user.reload.user_risk_state }.from("not_reviewed").to("suspended_for_tos_violation")

        expect(user.tos_violation_reason).to eq("General non-compliance")
      end
    end
  end
end
