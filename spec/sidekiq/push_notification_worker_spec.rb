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
                                                                  sound: Device::NOTIFICATION_SOUNDS[:sale],
                                                                  app_version: @device_b.app_version).and_return(android_b)
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

  it "sends a brand's notification to the phone of the team member who administers it" do
    brand = create(:user)
    member = create(:user)
    create(:team_membership, user: member, seller: brand, role: TeamMembership::ROLE_ADMIN)
    member_device = create(:device, user: member, app_type: Device::APP_TYPES[:creator])

    ios = double("ios_member")
    allow(PushNotificationService::Ios).to receive(:new).with(device_token: member_device.token,
                                                              title: "Title",
                                                              body: "Body",
                                                              data: {},
                                                              app_type: Device::APP_TYPES[:creator],
                                                              sound: Device::NOTIFICATION_SOUNDS[:sale]).and_return(ios)
    expect(ios).to receive(:process)

    PushNotificationWorker.new.perform(brand.id, Device::APP_TYPES[:creator], "Title", "Body", {}, Device::NOTIFICATION_SOUNDS[:sale], true)
  end

  it "stops sending a brand's notification to a phone whose membership was removed" do
    brand = create(:user)
    member = create(:user)
    membership = create(:team_membership, user: member, seller: brand, role: TeamMembership::ROLE_ADMIN)
    create(:device, user: member, app_type: Device::APP_TYPES[:creator])
    membership.update_as_deleted!

    expect(PushNotificationService::Ios).to_not receive(:new)
    expect(PushNotificationService::Android).to_not receive(:new)

    PushNotificationWorker.new.perform(brand.id, Device::APP_TYPES[:creator], "Title", "Body", {}, Device::NOTIFICATION_SOUNDS[:sale], true)
  end

  it "keeps a seller's purchase notification off the phones of their team admins" do
    seller = create(:user)
    admin = create(:user)
    create(:team_membership, user: admin, seller: seller, role: TeamMembership::ROLE_ADMIN)
    admin_device = create(:device, user: admin, app_type: Device::APP_TYPES[:consumer])
    seller_device = create(:device, user: seller, app_type: Device::APP_TYPES[:consumer])

    ios = double("ios_seller")
    allow(PushNotificationService::Ios).to receive(:new).with(device_token: seller_device.token,
                                                              title: "Post",
                                                              body: "By seller",
                                                              data: { "purchase_id" => "purchase_1" },
                                                              app_type: Device::APP_TYPES[:consumer],
                                                              sound: nil).and_return(ios)
    expect(ios).to receive(:process)
    expect(PushNotificationService::Ios).to_not receive(:new).with(hash_including(device_token: admin_device.token))

    PushNotificationWorker.new.perform(seller.id, Device::APP_TYPES[:consumer], "Post", "By seller", { "purchase_id" => "purchase_1" })
  end
end
