# frozen_string_literal: true

require "spec_helper"

describe PushNotificationWorker do
  before do
    @user = create(:user)
    @device_a = create(:device, user: @user)
    @device_b = create(:android_device, user: @user)
    @device_c = create(:device, user: @user)
  end

  it "sends the notification to each of the user's devices" do
    ios_a = double("ios_a")
    ios_c = double("ios_c")
    android_b = double("android_b")
    allow(PushNotificationService::Ios).to receive(:new).with(device_token: @device_a.token,
                                                              title: "Title",
                                                              body: "Body",
                                                              data: {},
                                                              app_type: Device::APP_TYPES[:creator],
                                                              sound: Device::NOTIFICATION_SOUNDS[:sale]).and_return(ios_a)
    allow(PushNotificationService::Ios).to receive(:new).with(device_token: @device_c.token,
                                                              title: "Title",
                                                              body: "Body",
                                                              data: {},
                                                              app_type: Device::APP_TYPES[:creator],
                                                              sound: Device::NOTIFICATION_SOUNDS[:sale]).and_return(ios_c)

    allow(PushNotificationService::Android).to receive(:new).with(device_token: @device_b.token,
                                                                  title: "Title",
                                                                  body: "Body",
                                                                  data: {},
                                                                  app_type: Device::APP_TYPES[:creator],
                                                                  sound: Device::NOTIFICATION_SOUNDS[:sale]).and_return(android_b)
    expect(ios_a).to receive(:process)
    expect(ios_c).to receive(:process)
    expect(android_b).to receive(:process)

    PushNotificationWorker.new.perform(@user.id, Device::APP_TYPES[:creator], "Title", "Body", {}, Device::NOTIFICATION_SOUNDS[:sale])
  end


  it "sends the notification only to given app_type" do
    ios_a = double("ios_a")
    ios_d = double("ios_d")
    @device_d = create(:device, user: @user, app_type: Device::APP_TYPES[:consumer])
    allow(PushNotificationService::Ios).to receive(:new).with(device_token: @device_a.token,
                                                              title: "Title",
                                                              body: "Body",
                                                              data: {},
                                                              app_type: Device::APP_TYPES[:consumer],
                                                              sound: nil).and_return(ios_a)
    allow(PushNotificationService::Ios).to receive(:new).with(device_token: @device_d.token,
                                                              title: "Title",
                                                              body: "Body",
                                                              data: {},
                                                              app_type: Device::APP_TYPES[:consumer],
                                                              sound: nil).and_return(ios_d)

    expect(ios_a).to_not receive(:process)
    expect(ios_d).to receive(:process)

    PushNotificationWorker.new.perform(@user.id, Device::APP_TYPES[:consumer], "Title", "Body", {})
  end
end
