# frozen_string_literal: true

require "spec_helper"

describe Admin::UserRiskStatePresenter do
  describe "#props" do
    it "returns compliant state for a compliant user" do
      user = create(:compliant_user)

      expect(described_class.new(user).props).to include(
        status: "Compliant",
        user_risk_state: "compliant",
        suspended: false,
        flagged_for_fraud: false,
        flagged_for_tos_violation: false,
        on_probation: false,
        compliant: true,
        last_status_changed_at: nil
      )
    end

    it "returns suspended state for a suspended fraud user" do
      user = create(:user, user_risk_state: "suspended_for_fraud")

      expect(described_class.new(user).props).to include(
        status: "Suspended",
        user_risk_state: "suspended_for_fraud",
        suspended: true,
        flagged_for_fraud: false,
        compliant: false
      )
    end

    it "returns flagged state for a flagged fraud user" do
      user = create(:user, user_risk_state: "flagged_for_fraud")

      expect(described_class.new(user).props).to include(
        status: "Flagged",
        user_risk_state: "flagged_for_fraud",
        suspended: false,
        flagged_for_fraud: true,
        compliant: false
      )
    end

    it "returns the most recent risk-state comment timestamp" do
      user = create(:compliant_user)
      older_comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_FLAGGED, created_at: 2.days.ago)
      newer_comment = create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_COMPLIANT, created_at: 1.day.ago)
      create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, created_at: Time.current)

      expect(described_class.new(user).props[:last_status_changed_at]).to eq(newer_comment.created_at.as_json)
      expect(described_class.new(user).props[:last_status_changed_at]).not_to eq(older_comment.created_at.as_json)
    end
  end
end
