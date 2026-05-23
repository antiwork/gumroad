# frozen_string_literal: true


shared_examples_for "Deletable concern" do |factory_name|
test "marks object as deleted" do
    object = create(factory_name)

    expect do
      object.mark_deleted!
    end.to change { object.deleted? }.from(false).to(true)
  end

test "marks object as alive" do
    object = create(factory_name)
    object.mark_deleted!

    expect do
      object.mark_undeleted!
    end.to change { object.alive? }.from(false).to(true)
  end
end
