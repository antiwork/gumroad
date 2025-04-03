# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "inherits from Admin::BaseController" do
  it { expect(controller.class.ancestors.include?(Admin::BaseController)).to eq(true) }
end
