# frozen_string_literal: true

require "spec_helper"

describe "Alterity configuration" do
  describe "command template" do
    let(:command) { Alterity.config.command.call("users", "DROP COLUMN twitter_handle") }

    it "includes --preserve-triggers so migrations succeed on tables with existing triggers" do
      expect(command).to include("--preserve-triggers")
    end

    it "includes the altered table and alter argument" do
      expect(command).to include("t=users")
      expect(command).to include("--alter DROP COLUMN twitter_handle")
    end
  end
end
