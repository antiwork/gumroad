# frozen_string_literal: true

RSpec.configure do |config|
  config.around(:each, :without_circle_rate_limit) do |example|
    RSpec::Mocks.with_temporary_scope do
      allow_any_instance_of(CircleApi).to receive(:rate_limited_call).and_wrap_original do |_, &blk|
        blk.call
      end
      example.run
    end
  end
end
