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

    it "checks lag on the replica directly when there is exactly one" do
      allow(Alterity.config).to receive(:replicas_dsns).and_return(["replica-1.example.com,P=3306"])

      expect(command).to include("--check-replica-lag 'replica-1.example.com,P=3306'")
    end

    it "leaves lag checks to the DSN table when there are several replicas" do
      allow(Alterity.config).to receive(:replicas_dsns).and_return(["replica-1.example.com,P=3306", "replica-2.example.com,P=3306"])

      expect(command).not_to include("--check-replica-lag")
      expect(command).to include("--recursion-method 'dsn=D=percona,t=replicas_dsns'")
    end
  end
end
