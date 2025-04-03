# frozen_string_literal: true

class HandleNewUserComplianceInfoWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_compliance_info_id)
    user_compliance_info = UserComplianceInfo.find(user_compliance_info_id)
    StripeMerchantAccountManager.handle_new_user_compliance_info(user_compliance_info)
  end
end
