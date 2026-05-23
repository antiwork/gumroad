# frozen_string_literal: true

require "test_helper"

class HandleNewUserComplianceInfoWorkerTest < ActiveSupport::TestCase
  self.described_class = HandleNewUserComplianceInfoWorker


  context_ HandleNewUserComplianceInfoWorker do
  context_ "perform" do
      let(:user_compliance_info) { create(:user_compliance_info) }

  test "calls StripeMerchantAccountManager.handle_new_user_compliance_info with the user compliance info object" do
        expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).with(user_compliance_info)
        described_class.new.perform(user_compliance_info.id)
      end
    end
  end
end
