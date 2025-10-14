# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::SalesReportsController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }

  before(:each) do
    sign_in admin_user
  end

  describe "GET index" do
    let(:job_history) { '{"job_id":"123","country_code":"US","start_date":"2023-01-01","end_date":"2023-03-31","enqueued_at":"2023-01-01T00:00:00Z","status":"processing"}' }

    before do
      allow($redis).to receive(:lrange).with(RedisKey.sales_report_jobs, 0, 19).and_return([job_history])
    end

    it "renders the page" do
      get :index

      expect(response).to be_successful
      expect(response.body).to include("data-page")
      expect(response.body).to include("Admin/SalesReports/Index")

      data_page = response.body.match(/data-page="([^"]+)"/)[1]
      json_object = JSON.parse(CGI.unescapeHTML(data_page))
      props = json_object["props"]

      expect(props["title"]).to eq("Sales reports")
      expect(props["countries"]).to eq Compliance::Countries.for_select.map { |alpha2, name| [name, alpha2] }
      expect(props["job_history"]).to eq([JSON.parse(job_history)])
      expect(props["authenticity_token"]).to be_present
    end
  end

  describe "POST create" do
    let(:country_code) { "GB" }
    let(:start_date) { "2023-01-01" }
    let(:end_date) { "2023-03-31" }
    let(:params) do
      {
        sales_report: {
          country_code: country_code,
          start_date: start_date,
          end_date: end_date
        }
      }
    end

    before do
      allow($redis).to receive(:lpush)
      allow($redis).to receive(:ltrim)
    end

    it "enqueues a GenerateSalesReportJob with string dates" do
      post :create, params: params

      expect(GenerateSalesReportJob).to have_enqueued_sidekiq_job(
        country_code,
        start_date,
        end_date,
        true,
        nil
      )
    end

    it "stores job details in Redis" do
      expect($redis).to receive(:lpush).with(RedisKey.sales_report_jobs, anything)
      expect($redis).to receive(:ltrim).with(RedisKey.sales_report_jobs, 0, 19)

      post :create, params: params
    end

    it "returns success JSON response" do
      post :create, params: params

      expect(response).to be_successful
      expect(response.content_type).to include("application/json")

      json_response = JSON.parse(response.body)
      expect(json_response["success"]).to be true
      expect(json_response["message"]).to eq("Sales report job enqueued successfully!")
    end

    it "converts dates to strings before passing to job" do
      allow(GenerateSalesReportJob).to receive(:perform_async).and_return("job_id_123")

      post :create, params: params

      expect(GenerateSalesReportJob).to have_received(:perform_async).with(
        country_code,
        start_date,
        end_date,
        true,
        nil
      )
    end
  end
end
