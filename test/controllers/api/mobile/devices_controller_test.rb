# frozen_string_literal: true

require "test_helper"

class ApiMobileDevicesControllerTest < ActionController::TestCase
  self.described_class = Api::Mobile::DevicesController
  tests Api::Mobile::DevicesController



  context_ Api::Mobile::DevicesController do
    before do
      @user = create(:user)
      @app = create(:oauth_application, owner: @user)
    end

  context_ "POST create" do
  context_ "when making a request while unauthenticated" do
  test "fails" do
          post :create, params: { device: { token: "abc", device_type: "ios", app_version: "1.0.0" } }

          expect(response.code).to eq("401")
        end
      end

  context_ "when making a request with mobile_api scope" do
        let(:token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "mobile_api") }

  test "persists device token to the database" do
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

  test "deletes existing device token if already present" do
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
          end.not_to change { Device.count }

          expect do
            post :create, params: { mobile_token: Api::Mobile::BaseController::MOBILE_TOKEN, access_token: token.token, device: { token: "abc", device_type: "android" } }
          end.to change { Device.count }.by(1)
        end
      end

  context_ "when making a request with creator_api scope" do
        let(:token) { create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "creator_api") }

  test "persists device token to the database" do
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

  test "does not pass down unfiltered params to the database" do
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
end
