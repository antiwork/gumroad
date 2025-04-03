# frozen_string_literal: true

class PushNotificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :critical

  def perform(receiver_id, app_type, title, body = nil, data = {}, sound = nil)
    receiver = User.find receiver_id

    receiver.devices.where(app_type:).each do |device|
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
                                             sound:).process
      end
    end
  end
end
