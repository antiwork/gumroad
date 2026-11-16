# frozen_string_literal: true

RSpec.describe "config/storage.yml" do
  # Test and development point AWS_S3_ENDPOINT at MinIO, but production uses real S3 and never sets
  # it. These examples build the service the way production does, which the rest of the suite can't.
  def build_service(name)
    configs = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
    ActiveStorage::Service::Registry.new(configs).fetch(name)
  end

  def endpoint_of(service)
    service.client.client.config.endpoint.to_s
  end

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
  end

  describe "commission_files" do
    it "builds on the default AWS endpoint when AWS_S3_ENDPOINT is not set, as in production" do
      allow(GlobalConfig).to receive(:get).with("AWS_S3_ENDPOINT").and_return(nil)

      expect(endpoint_of(build_service(:commission_files))).to end_with(".amazonaws.com")
    end

    it "uses AWS_S3_ENDPOINT when it is set, as for MinIO" do
      allow(GlobalConfig).to receive(:get).with("AWS_S3_ENDPOINT").and_return("http://minio.test:9000")

      expect(endpoint_of(build_service(:commission_files))).to eq("http://minio.test:9000")
    end
  end
end
