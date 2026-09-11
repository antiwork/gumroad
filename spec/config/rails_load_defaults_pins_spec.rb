# frozen_string_literal: true

require "spec_helper"

# Assert runtime destinations, not Rails.application.config: a pin can sit on the
# config object and never reach the framework (rails/rails#58145).
# to_time_preserves_timezone has no runtime destination left in 8.1.
describe "load_defaults pins" do
  it "runs the framework defaults for the version application.rb declares" do
    # Stored verbatim from the load_defaults argument, so it is the Float 8.1, not "8.1".
    expect(Rails.application.config.loaded_config_version.to_s).to eq("8.1")
  end

  it "keeps conditional requests satisfying both If-Modified-Since and If-None-Match" do
    expect(ActionDispatch::Http::Cache::Request.strict_freshness).to be(false)
  end

  it "leaves Regexp.timeout unset" do
    expect(Regexp.timeout).to be_nil
  end

  it "keeps JSON responses HTML-escaped" do
    expect(ActionController::Base.escape_json_responses).to be(true)
  end

  it "keeps JS line separators escaped in JSON" do
    expect(ActiveSupport::JSON::Encoding.escape_js_separators_in_json).to be(true)
  end

  it "keeps implicit finder order a warning rather than an error" do
    expect(ActiveRecord.raise_on_missing_required_finder_order_columns).to be(false)
  end

  it "keeps the regex render tracker" do
    expect(ActionView.render_tracker).to eq(:regex)
  end

  it "keeps autocomplete attributes on hidden fields" do
    expect(ActionView::Base.remove_hidden_field_autocomplete).to be(false)
  end

  # No runtime destination: Rails' :yjit initializer only ever enables, so config is the switch.
  # load_defaults 8.1 turns YJIT on outside dev/test, and these hosts have little memory headroom.
  it "keeps YJIT off" do
    expect(Rails.application.config.yjit).to be(false)
  end

  # action_on_path_relative_redirect is intentionally unpinned: 8.1's :raise is a security
  # check the app wants. Asserted so a later "restore the 8.0 behaviour" pass has to be deliberate.
  it "adopts the 8.1 path-relative redirect guard" do
    expect(Rails.application.config.action_controller.action_on_path_relative_redirect).to eq(:raise)
  end
end
