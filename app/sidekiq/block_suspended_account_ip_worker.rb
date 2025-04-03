# frozen_string_literal: true

class BlockSuspendedAccountIpWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(user_id)
    user = User.find(user_id)
    return if user.last_sign_in_ip.blank?
    return if User.where(
      "(current_sign_in_ip = :ip OR last_sign_in_ip = :ip OR account_created_ip = :ip) and user_risk_state = :risk_state",
      { ip: user.last_sign_in_ip, risk_state: "compliant" }
    ).exists?

    BlockedObject.block!(
      BLOCKED_OBJECT_TYPES[:ip_address],
      user.last_sign_in_ip,
      nil,
      expires_in: BlockedObject::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months
    )
  end
end
