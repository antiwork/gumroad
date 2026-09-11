# frozen_string_literal: true

require "spec_helper"

# config/application.rb advances load_defaults ahead of the behaviour the app has adopted,
# then pins each deferred default back. Assert the runtime destinations rather than
# Rails.application.config: a pin can be present in the config object and still never reach
# the framework if it is applied after the railtie has read it (rails/rails#58145 is the
# same failure for default_headers). Each later step in the upgrade re-bumps load_defaults,
# and a dropped pin changes behaviour silently.
#
# to_time_preserves_timezone is deliberately absent: Rails 8.1 deletes
# DateAndTime::Compatibility.preserve_timezone and leaves only a deprecated accessor over
# an ivar, so there is no runtime destination left to assert.
describe "load_defaults pins" do
  it "runs the framework defaults for the version application.rb declares" do
    # Stored verbatim from the load_defaults argument, so it is the Float 8.0, not "8.0".
    expect(Rails.application.config.loaded_config_version.to_s).to eq("8.0")
  end

  it "keeps conditional requests satisfying both If-Modified-Since and If-None-Match" do
    expect(ActionDispatch::Http::Cache::Request.strict_freshness).to be(false)
  end

  it "leaves Regexp.timeout unset" do
    expect(Regexp.timeout).to be_nil
  end
end
