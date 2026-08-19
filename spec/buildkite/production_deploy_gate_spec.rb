# frozen_string_literal: true

require "spec_helper"
require "yaml"

# A block step with no depends_on implicitly waits for every earlier step, so the gate only
# became unblockable after ~17 minutes of image builds and asset compiles — while the tests
# workflow finishes in ~11 and burned its unblock retries on "no build found". The gate must
# stay dependency-free; the deploy step's own depends_on is what holds deploys until assets pass.
RSpec.describe "Production deploy approval gate" do
  let(:steps) { YAML.safe_load_file(Rails.root.join(".buildkite/pipeline.yml")).fetch("steps") }
  let(:gate) { steps.find { _1.is_a?(Hash) && _1["key"] == "require-approval" } }
  let(:deploy) { steps.find { _1.is_a?(Hash) && _1["key"] == "production-deployment" } }

  it "declares the gate with an explicit empty depends_on so it is unblockable from build start" do
    expect(gate).to be_present
    expect(gate).to have_key("depends_on")
    expect(gate["depends_on"]).to be_blank
  end

  it "keeps the deploy step waiting on both compiled assets and the approval" do
    expect(deploy["depends_on"]).to match_array(["compile-assets", "require-approval"])
  end
end
