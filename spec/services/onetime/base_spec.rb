# frozen_string_literal: true

require "spec_helper"

RSpec.describe Onetime::Base do
  class Onetime::TestScript < Onetime::Base
    def process(message)
      Rails.logger.info(message)
    end
  end

  let(:time_now) { Time.current }
  let(:created_log_files) { [] }
  let(:script_instance) { Onetime::TestScript.new }
  let(:message) { "Hello, world!" }

  before do
    allow(Time).to receive(:current).and_return(time_now)

    allow(script_instance).to receive(:enable_logger).and_wrap_original do |method, _|
      log_file_name = "log/test_script_#{time_now.strftime('%Y-%m-%d_%H-%M-%S')}.log"
      created_log_files << Rails.root.join(log_file_name)
      method.call
    end
  end

  after(:each) do
    created_log_files.each { FileUtils.rm_f(_1) }
    created_log_files.clear
  end

  describe "#process_with_logging" do
    it "calls the process method" do
      expect(script_instance).to receive(:process)
      script_instance.process_with_logging(message)
    end

    it "logs the start and finish times" do
      expect(Rails.logger).to receive(:info).with("Started process at #{time_now}")
      expect(Rails.logger).to receive(:info).with(message)
      expect(Rails.logger).to receive(:info).with("Finished process at #{time_now} in 0.0 seconds")
      script_instance.process_with_logging(message)
    end

    it "creates and closes a custom logger" do
      expect(Logger).to receive(:new).and_call_original
      expect_any_instance_of(Logger).to receive(:close)
      script_instance.process_with_logging(message)
    end
  end
end
