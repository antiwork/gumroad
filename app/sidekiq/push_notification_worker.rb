# frozen_string_literal: true

class PushNotificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :critical

  def perform(receiver_id, app_type, title, body = nil, data = {}, sound = nil)
    receiver = User.find receiver_id

    devices_for(receiver, app_type).each do |device|
      case device.device_type
      when "ios"
        PushNotificationService::Ios.new(device_token: device.token,
                                         title:,
                                         body:,
                                         data:,
                                         app_type:,
                                         sound:).process
      when "android"
        PushNotificationService::Android.new(device_token: device.token,
                                             title:,
                                             body:,
                                             data:,
                                             app_type:,
                                             sound:,
                                             app_version: device.app_version).process
      end
    end
  end

  private
    # A brand's sale has to reach the phones of the team members who administer it, not only the
    # brand's own devices: the app keeps a phone on the member while a brand token is active (see
    # `Api::Mobile::DevicesController`), and only the members the app would let switch in count.
    # The memberships are read here, at send time, so a member whose access was removed — or whose
    # account is gone — stops receiving without the phone having to do anything.
    def devices_for(receiver, app_type)
      member_ids = TeamMembership.role_admin.not_deleted.joins(:user).merge(User.alive)
                                  .where(seller_id: receiver.id).pluck(:user_id)
      return receiver.devices.where(app_type:) if member_ids.empty?

      Device.where(app_type:, user_id: [receiver.id, *member_ids])
    end
end
