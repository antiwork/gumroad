# frozen_string_literal: true

require "spec_helper"

describe Api::Mobile::DevicesController do
  before do
    @user = create(:user)
    @app = create(:oauth_application, owner: @user)
  end

  describe "POST create" do
    context "when making a request while unauthenticated" do
      it "fails" do
        post :create, params: { device: { token: "abc", device_type: "ios", app_version: "1.0.0" } }

        expect(response.code).to eq("401")
      end
    end

    context "when making a request with mobile_api scope" do
      let(:token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "mobile_api") }

      it "persists device token to the database" do
        expect do
          post :create, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, device: { token: "abc", device_type: "ios", app_type: Device::APP_TYPES[:creator], app_version: "1.0.0" } }
        end.to change { Device.count }.by(1)

        expect(response.parsed_body).to eq({ success: true }.as_json)

        created_device = @user.devices.first
        expect(created_device).to be_present
        expect(created_device.token).to eq "abc"
        expect(created_device.device_type).to eq "ios"
        expect(created_device.app_type).to eq Device::APP_TYPES[:creator]
        expect(created_device.app_version).to eq "1.0.0"
      end

      it "deletes existing device token if already present" do
        expect do
          post :create, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, device: { token: "abc", device_type: "ios", app_type: Device::APP_TYPES[:creator], app_version: "1.0.0" } }
        end.to change { Device.count }.by(1)

        expect(response.parsed_body).to eq({ success: true }.as_json)

        created_device = @user.devices.first
        expect(created_device).to be_present
        expect(created_device.token).to eq "abc"
        expect(created_device.device_type).to eq "ios"
        expect(created_device.app_type).to eq Device::APP_TYPES[:creator]
        expect(created_device.app_version).to eq "1.0.0"

        expect do
          post :create, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, device: { token: "abc", device_type: "ios" } }
        end.to_not change { Device.count }

        expect do
          post :create, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, device: { token: "abc", device_type: "android" } }
        end.to change { Device.count }.by(1)
      end
    end

    context "when making a request with creator_api scope" do
      let(:token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "creator_api") }

      it "persists device token to the database" do
        expect do
          post :create, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, device: { token: "abc", device_type: "ios", app_type: Device::APP_TYPES[:creator], app_version: "1.0.0" } }
        end.to change { Device.count }.by(1)

        expect(response.parsed_body).to eq({ success: true }.as_json)

        created_device = @user.devices.first
        expect(created_device).to be_present
        expect(created_device.token).to eq "abc"
        expect(created_device.device_type).to eq "ios"
        expect(created_device.app_type).to eq Device::APP_TYPES[:creator]
        expect(created_device.app_version).to eq "1.0.0"
      end

      it "does not pass down unfiltered params to the database" do
        expect do
          post :create, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, device: { token: "abc", device_type: "ios", app_type: Device::APP_TYPES[:creator], app_version: "1.0.0", unsafe_param: "UNSAFE" } }
        end.to change { Device.count }.by(1)

        expect(response.parsed_body).to eq({ success: true }.as_json)

        created_device = @user.devices.first
        expect(created_device).to be_present
        expect(created_device.token).to eq "abc"
        expect(created_device.device_type).to eq "ios"
        expect(created_device.app_type).to eq Device::APP_TYPES[:creator]
        expect(created_device.app_version).to eq "1.0.0"
      end
    end
  end
end
