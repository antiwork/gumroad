# frozen_string_literal: true

require "spec_helper"

describe GumroadRuntimeError do
  describe "without message or original error" do
    before do
      raise GumroadRuntimeError
    rescue GumroadRuntimeError => error
      @error = error
    end

    it "has the default message" do
      expect(@error.message).to eq "GumroadRuntimeError"
    end

    it "has its own backtrace" do
      expect(@error.backtrace[0]).to include("gumroad_runtime_error_spec.rb")
    end
  end

  describe "with message" do
    before do
      raise GumroadRuntimeError, "the-message"
    rescue GumroadRuntimeError => error
      @error = error
    end

    it "has the message" do
      expect(@error.message).to eq "the-message"
    end
  end

  describe "with original error" do
    before do
      begin
        raise StandardError
      rescue StandardError => original_error
        raise GumroadRuntimeError.new(original_error:)
      end
    rescue GumroadRuntimeError => error
      @error = error
    end

    it "has the message of the original error" do
      expect(@error.message).to eq "StandardError"
    end
  end

  describe "with original error that has a message" do
    before do
      begin
        raise StandardError, "standard error message"
      rescue StandardError => original_error
        raise GumroadRuntimeError.new(original_error:)
      end
    rescue GumroadRuntimeError => error
      @error = error
    end

    it "has the message of the original error" do
      expect(@error.message).to eq "standard error message"
    end
  end

  describe "with message and original error" do
    before do
      begin
        raise StandardError
      rescue StandardError => original_error
        raise GumroadRuntimeError.new("the-error-message", original_error:)
      end
    rescue GumroadRuntimeError => error
      @error = error
    end

    it "has the message of the original error" do
      expect(@error.message).to eq "the-error-message"
    end
  end
end
