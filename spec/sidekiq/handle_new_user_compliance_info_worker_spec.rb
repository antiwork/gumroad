# frozen_string_literal: true

describe HandleNewUserComplianceInfoWorker do
  describe "perform" do
    let(:user_compliance_info) { create(:user_compliance_info) }

    it "calls StripeMerchantAccountManager.handle_new_user_compliance_info with the user compliance info object" do
      expect(StripeMerchantAccountManager).to receive(:handle_new_user_compliance_info).with(user_compliance_info)
      described_class.new.perform(user_compliance_info.id)
    end
  end
end
