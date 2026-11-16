# frozen_string_literal: true

RSpec.describe "config/storage.yml" do
  # Test and development point AWS_S3_ENDPOINT at MinIO, but production uses real S3 and never sets
  # it. These examples build the service the way production does, which the rest of the suite can't.
  def storage_configs
    ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/storage.yml"))
  end

  def build_service(name)
    ActiveStorage::Service::Registry.new(storage_configs).fetch(name)
  end

  def endpoint_of(service)
    service.client.client.config.endpoint.to_s
  end

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
  end

  describe "commission_files" do
    context "when AWS_S3_ENDPOINT is not set, as in production" do
      before do
        allow(GlobalConfig).to receive(:get).with("AWS_S3_ENDPOINT").and_return(nil)
        # config/initializers/aws.rb also sets a global MinIO endpoint, but only in development and test.
        allow(Aws).to receive(:config).and_return(Aws.config.except(:endpoint))
      end

      it "leaves the endpoint key out, since the AWS SDK raises on an explicit nil" do
        expect(storage_configs["commission_files"]).not_to have_key("endpoint")
      end

      it "builds on the default AWS endpoint" do
        expect(endpoint_of(build_service(:commission_files))).to end_with(".amazonaws.com")
      end
    end

    it "uses AWS_S3_ENDPOINT when it is set, as for MinIO" do
      allow(GlobalConfig).to receive(:get).with("AWS_S3_ENDPOINT").and_return("http://minio.test:9000")

      expect(endpoint_of(build_service(:commission_files))).to eq("http://minio.test:9000")
    end
  end
end
