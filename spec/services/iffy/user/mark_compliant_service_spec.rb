# frozen_string_literal: true

require "spec_helper"

describe Iffy::User::MarkCompliantService do
  describe "#perform" do
    let(:user) { create(:user, user_risk_state: :suspended_for_tos_violation) }
    let(:service) { described_class.new(user.external_id) }

    it "marks the user as compliant and adds a comment with Iffy as the author" do
      expect_any_instance_of(User).to receive(:mark_compliant!).with(author_name: "Iffy").and_call_original

      expect do
        service.perform
      end.to change { user.reload.user_risk_state }.from("suspended_for_tos_violation").to("compliant")
    end
  end
end
