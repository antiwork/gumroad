# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/string_inquirer"

describe "IRAS configuration" do
  let(:configuration) { Module.new }
  let(:global_config) { double("GlobalConfig") }

  before do
    configuration.const_set(:GlobalConfig, global_config)
    allow(global_config).to receive(:get).with("IRAS_API_ID").and_return("legacy-api-id")
    allow(global_config).to receive(:get).with("IRAS_API_SECRET").and_return("legacy-api-secret")
  end

  {
    "production" => {
      apex: "https://public.api.gov.sg/iras/GSTListing/v1/SearchGSTRegistered",
      legacy: "https://apiservices.iras.gov.sg/iras/prod/GSTListing/SearchGSTRegistered"
    },
    "staging" => {
      apex: "https://sandbox.api.gov.sg/iras/GSTListing/v1/SearchGSTRegistered",
      legacy: "https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered"
    },
    "test" => {
      apex: "https://sandbox.api.gov.sg/iras/GSTListing/v1/SearchGSTRegistered",
      legacy: "https://apisandbox.iras.gov.sg/iras/sb/GSTListing/SearchGSTRegistered"
    }
  }.each do |environment, endpoints|
    context "in #{environment}" do
      before do
        configuration.const_set(:Rails, double(env: ActiveSupport::StringInquirer.new(environment)))
      end

      [nil, "", "   ", "test-apex-api-key"].each do |api_key|
        it "selects #{api_key.present? ? "APEX" : "IBM"} when the APEX key is #{api_key.inspect}" do
          allow(global_config).to receive(:get).with("IRAS_APEX_API_KEY").and_return(api_key)
          configuration.module_eval(File.read(File.expand_path("../../config/initializers/iras.rb", __dir__)))

          expect(configuration::IRAS_APEX_API_KEY).to eq(api_key)
          expect(configuration::IRAS_ENDPOINT).to eq(endpoints.fetch(api_key.present? ? :apex : :legacy))
        end
      end
    end
  end
end
