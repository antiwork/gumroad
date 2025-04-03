# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "Deletable concern" do |factory_name|
  it "marks object as deleted" do
    object = create(factory_name)

    expect do
      object.mark_deleted!
    end.to change { object.deleted? }.from(false).to(true)
  end

  it "marks object as alive" do
    object = create(factory_name)
    object.mark_deleted!

    expect do
      object.mark_undeleted!
    end.to change { object.alive? }.from(false).to(true)
  end
end
