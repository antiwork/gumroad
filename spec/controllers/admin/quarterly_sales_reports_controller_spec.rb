# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::QuarterlySalesReportsController do
  render_views

  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  before(:each) do
    sign_in admin_user
  end

  describe "GET index" do
    it "renders the page" do
      get :index

      expect(response).to be_successful
      expect(response).to render_template(:index)
    end

    it "sets the page title" do
      get :index

      expect(assigns(:title)).to eq("Sales reports")
    end

    it "loads countries for dropdown" do
      get :index

      expect(assigns(:countries)).to be_present
      expect(assigns(:countries).first).to be_an(Array)
      expect(assigns(:countries).first.size).to eq(2)
    end

    it "loads job history from Redis" do
      allow($redis).to receive(:lrange).with(RedisKey.quarterly_sales_report_jobs, 0, 19).and_return(['{"job_id":"123","status":"processing"}'])
      
      get :index

      expect(assigns(:job_history)).to be_present
      expect(assigns(:job_history).first["job_id"]).to eq("123")
    end
  end

  describe "POST create" do
    let(:country_code) { "GB" }
    let(:start_date) { "2023-01-01" }
    let(:end_date) { "2023-03-31" }
    let(:params) do
      {
        quarterly_sales_report: {
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

    it "enqueues a GenerateQuarterlySalesReportJob" do
      post :create, params: params

      expect(GenerateQuarterlySalesReportJob).to have_enqueued_sidekiq_job(
        country_code,
        Date.parse(start_date),
        Date.parse(end_date),
        true,
        nil
      )
    end

    it "stores job details in Redis" do
      expect($redis).to receive(:lpush).with(RedisKey.quarterly_sales_report_jobs, anything)
      expect($redis).to receive(:ltrim).with(RedisKey.quarterly_sales_report_jobs, 0, 19)

      post :create, params: params
    end

    it "redirects with success notice" do
      post :create, params: params

      expect(response).to redirect_to(admin_quarterly_sales_reports_path)
      expect(flash[:notice]).to eq("Sales report job enqueued successfully!")
    end

    it "parses dates correctly" do
      allow(GenerateQuarterlySalesReportJob).to receive(:perform_async).and_return("job_id_123")

      post :create, params: params

      expect(GenerateQuarterlySalesReportJob).to have_received(:perform_async).with(
        country_code,
        Date.new(2023, 1, 1),
        Date.new(2023, 3, 31),
        true,
        nil
      )
    end
  end

  describe "private methods" do
    describe "#fetch_job_history" do
      it "returns parsed job data from Redis" do
        job_data = ['{"job_id":"123","status":"processing"}', '{"job_id":"456","status":"completed"}']
        allow($redis).to receive(:lrange).with(RedisKey.quarterly_sales_report_jobs, 0, 19).and_return(job_data)

        controller = described_class.new
        result = controller.send(:fetch_job_history)

        expect(result).to eq([
          {"job_id" => "123", "status" => "processing"},
          {"job_id" => "456", "status" => "completed"}
        ])
      end

      it "returns empty array on JSON parse error" do
        allow($redis).to receive(:lrange).with(RedisKey.quarterly_sales_report_jobs, 0, 19).and_return(['invalid json'])

        controller = described_class.new
        result = controller.send(:fetch_job_history)

        expect(result).to eq([])
      end
    end
  end
end
