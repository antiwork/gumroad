# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "inherits from Sellers::BaseController" do
  it { expect(controller.class.ancestors.include?(Sellers::BaseController)).to eq(true) }
end
