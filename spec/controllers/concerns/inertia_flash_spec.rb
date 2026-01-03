# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe "Inertia flash data", type: :controller, inertia: true do
  controller(ApplicationController) do
    include InertiaRendering

    def index
      flash[:notice] = "Success message"
      render inertia: "Test/Index"
    end

    def alert_action
      flash[:alert] = "Error message"
      render inertia: "Test/Index"
    end

    def warning_action
      flash[:warning] = "Warning message"
      render inertia: "Test/Index"
    end

    def multiple_flash
      # Note: Only the first flash (by priority: alert > warning > notice) is shown
      flash[:notice] = "Success"
      flash[:warning] = "Also warning"
      render inertia: "Test/Index"
    end

    def redirect_with_flash
      redirect_to "/target", notice: "Redirected successfully"
    end

    def no_flash
      render inertia: "Test/Index"
    end
  end

  before do
    routes.draw do
      get "index" => "anonymous#index"
      get "alert_action" => "anonymous#alert_action"
      get "warning_action" => "anonymous#warning_action"
      get "multiple_flash" => "anonymous#multiple_flash"
      get "redirect_with_flash" => "anonymous#redirect_with_flash"
      get "no_flash" => "anonymous#no_flash"
      get "target" => "anonymous#index"
    end
  end

  describe "flash data structure" do
    it "includes flash notice in props with unique ID" do
      request.headers["X-Inertia"] = "true"

      get :index

      page = JSON.parse(response.body)
      flash_data = page["props"]["flash"]
      expect(flash_data["message"]).to eq("Success message")
      expect(flash_data["status"]).to eq("success")
      expect(flash_data["id"]).to be_present
    end

    it "includes flash alert in props with danger status" do
      request.headers["X-Inertia"] = "true"

      get :alert_action

      page = JSON.parse(response.body)
      flash_data = page["props"]["flash"]
      expect(flash_data["message"]).to eq("Error message")
      expect(flash_data["status"]).to eq("danger")
      expect(flash_data["id"]).to be_present
    end

    it "includes flash warning in props with warning status" do
      request.headers["X-Inertia"] = "true"

      get :warning_action

      page = JSON.parse(response.body)
      flash_data = page["props"]["flash"]
      expect(flash_data["message"]).to eq("Warning message")
      expect(flash_data["status"]).to eq("warning")
      expect(flash_data["id"]).to be_present
    end

    it "prioritizes alert over warning and notice" do
      request.headers["X-Inertia"] = "true"

      get :multiple_flash

      page = JSON.parse(response.body)
      flash_data = page["props"]["flash"]
      # Warning takes priority over notice (alert > warning > notice)
      expect(flash_data["message"]).to eq("Also warning")
      expect(flash_data["status"]).to eq("warning")
    end

    it "generates unique IDs for each request" do
      request.headers["X-Inertia"] = "true"

      get :index
      first_page = JSON.parse(response.body)
      first_id = first_page["props"]["flash"]["id"]

      get :index
      second_page = JSON.parse(response.body)
      second_id = second_page["props"]["flash"]["id"]

      expect(first_id).not_to eq(second_id)
    end

    it "does not include flash in props when no flash is set" do
      request.headers["X-Inertia"] = "true"

      get :no_flash

      page = JSON.parse(response.body)
      expect(page["props"]["flash"]).to be_nil
    end
  end

  describe "redirect with flash" do
    it "preserves flash through redirect for Inertia requests" do
      request.headers["X-Inertia"] = "true"

      get :redirect_with_flash

      expect(response).to be_redirect
      expect(flash[:notice]).to eq("Redirected successfully")
    end
  end

  describe "non-Inertia requests" do
    it "does not break regular Rails flash for non-Inertia requests" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(flash[:notice]).to eq("Success message")
    end
  end
end
