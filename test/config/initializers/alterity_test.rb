# frozen_string_literal: true

require "test_helper"

class ConfigInitializersAlterityTest < ActiveSupport::TestCase



  context_ "Alterity configuration" do
  context_ "command template" do
      let(:command) { Alterity.config.command.call("users", "DROP COLUMN twitter_handle") }

  test "includes --preserve-triggers so migrations succeed on tables with existing triggers" do
        expect(command).to include("--preserve-triggers")
      end

  test "includes the altered table and alter argument" do
        expect(command).to include("t=users")
        expect(command).to include("--alter DROP COLUMN twitter_handle")
      end
    end
  end
end
