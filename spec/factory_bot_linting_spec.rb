# frozen_string_literal: true

require "support/factory_bot_linting.rb"

RSpec.describe FactoryBotLinting do
  it "#process" do
    expect { described_class.new.process }.to_not raise_error
  end
end
