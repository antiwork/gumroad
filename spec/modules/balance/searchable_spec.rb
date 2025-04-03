# frozen_string_literal: true

require "spec_helper"

describe Balance::Searchable do
  it "includes ElasticsearchModelAsyncCallbacks" do
    expect(Balance).to include(ElasticsearchModelAsyncCallbacks)
  end
end
