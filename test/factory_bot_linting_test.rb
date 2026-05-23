# frozen_string_literal: true

require "test_helper"
require "support/factory_bot_linting.rb"

class FactoryBotLintingTest < ActiveSupport::TestCase
  self.described_class = FactoryBotLinting



  context_ FactoryBotLinting do
  test "#process" do
      expect { described_class.new.process }.not_to raise_error
    end
  end
end
