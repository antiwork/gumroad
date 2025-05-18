# frozen_string_literal: true

require "spec_helper"

describe ResetAdminActionCallCountsJob do
  describe "#perform" do
    it "recreates admin action call infos" do
      create(:admin_action_call_info, call_count: 25)
      create(:admin_action_call_info, controller_name: "NoLongerExistingController", call_count: 3)
      described_class.new.perform

      expect(AdminActionCallInfo.where(action_name: "index")).to be_present
      expect(AdminActionCallInfo.where("call_count > 0")).to be_empty
      expect(AdminActionCallInfo.where(controller_name: "NoLongerExistingController")).to be_empty
    end
  end
end
