# frozen_string_literal: true

class CreateStripeMerchantAccountWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    StripeMerchantAccountManager.create_account(user, passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"))
  end
end
