# frozen_string_literal: true

require "spec_helper"

describe Immutable do
  let(:today) { Date.today }

  # This can be any model, but I'm using the UserComplianceInfo model for the tests. I could not
  # find a way to create a mock model which included JsonData.
  let(:model) do
    build(:user_compliance_info)
  end

  describe "creating" do
    it "is able to create a record" do
      model.save!
    end
  end

  describe "updating" do
    before do
      model.save!
    end

    describe "no changes" do
      it "is able to update a record with no changes" do
        model.save!
      end
    end

    describe "changes allowed" do
      before do
        model.deleted_at = Time.current
      end

      it "is able to update the record" do
        model.save!
      end
    end

    describe "changes not allowed" do
      before do
        model.first_name = "Santa Clause"
      end

      it "isn't able to update the record" do
        expect { model.save! }.to raise_error(Immutable::RecordImmutable)
      end
    end
  end

  describe "#dup_and_save" do
    let(:model) { create(:user_compliance_info, birthday: today - 30.years) }

    describe "changes are valid" do
      before do
        @result, @new_model = model.dup_and_save do |new_model|
          new_model.birthday = today - 20.years
        end
        model.reload
        @new_model.reload
      end

      it "returns a result of true" do
        expect(@result).to eq(true)
      end

      it "returns a duplicate of the model" do
        expect(@new_model.class).to eq(model.class)
        expect(@new_model.first_name).to eq(model.first_name)
        expect(@new_model.last_name).to eq(model.last_name)
      end

      it "returns a model with the change made" do
        expect(@new_model.birthday).not_to eq(model.birthday)
        expect(@new_model.birthday).to eq(today - 20.years)
      end

      it "returns a duplicate of the model with an id since its been persisted" do
        expect(@new_model.id).to be_present
      end

      it "marks the original model as deleted" do
        expect(model).to be_deleted
      end
    end

    describe "changes are valid, original values are invalid" do
      before do
        model.update_column("birthday", today)
        @result, @new_model = model.dup_and_save do |new_model|
          new_model.birthday = today - 20.years
        end
        model.reload
        @new_model.reload
      end

      it "returns a result of true" do
        expect(@result).to eq(true)
      end

      it "returns a duplicate of the model" do
        expect(@new_model.class).to eq(model.class)
        expect(@new_model.first_name).to eq(model.first_name)
        expect(@new_model.last_name).to eq(model.last_name)
      end

      it "returns a model with the change made" do
        expect(@new_model.birthday).not_to eq(model.birthday)
        expect(@new_model.birthday).to eq(today - 20.years)
      end

      it "returns a duplicate of the model with an id since its been persisted" do
        expect(@new_model.id).to be_present
      end

      it "marks the original model as deleted" do
        expect(model).to be_deleted
      end
    end

    describe "changes are invalid" do
      before do
        @result, @new_model = model.dup_and_save do |new_model|
          new_model.birthday = today
        end
        model.reload
      end

      it "returns a result of true" do
        expect(@result).to eq(false)
      end

      it "returns a duplicate of the model" do
        expect(@new_model.class).to eq(model.class)
        expect(@new_model.first_name).to eq(model.first_name)
        expect(@new_model.last_name).to eq(model.last_name)
      end

      it "returns a model with the change made" do
        expect(@new_model.birthday).not_to eq(model.birthday)
        expect(@new_model.birthday).to eq(today)
      end

      it "returns a duplicate of the model without an id since it hasn't been persisted" do
        expect(@new_model.id).to eq(nil)
        # Note: We can't use `persisted?` here to test if it's been persisted, because the model was rolled back
        # it's persisted flag got set to that of the record it duplicated and it will be true, even though it isn't.
      end

      it "does not mark the original model as deleted" do
        expect(model).not_to be_deleted
      end
    end
  end

  describe "#dup_and_save!" do
    let(:model) { create(:user_compliance_info, birthday: today - 30.years) }

    describe "changes are valid" do
      before do
        @result, @new_model = model.dup_and_save! do |new_model|
          new_model.birthday = today - 20.years
        end
        model.reload
        @new_model.reload
      end

      it "returns a result of true" do
        expect(@result).to eq(true)
      end

      it "returns a duplicate of the model" do
        expect(@new_model.class).to eq(model.class)
        expect(@new_model.first_name).to eq(model.first_name)
        expect(@new_model.last_name).to eq(model.last_name)
      end

      it "returns a model with the change made" do
        expect(@new_model.birthday).not_to eq(model.birthday)
        expect(@new_model.birthday).to eq(today - 20.years)
      end

      it "returns a duplicate of the model with an id since its been persisted" do
        expect(@new_model.id).to be_present
      end

      it "marks the original model as deleted" do
        expect(model).to be_deleted
      end
    end

    describe "changes are invalid" do
      it "raises a validation error" do
        expect do
          model.dup_and_save! do |new_model|
            new_model.birthday = today
          end
        end.to raise_error(ActiveRecord::RecordInvalid)
      end

      describe "after the error is raised" do
        before do
          @model_id = model.id
          expect do
            model.dup_and_save! do |new_model|
              new_model.birthday = today
            end
          end.to raise_error(ActiveRecord::RecordInvalid)
        end

        it "does not have created a new record" do
          model = UserComplianceInfo.find(@model_id)
          expect(model.user.user_compliance_infos.count).to eq(1)
        end

        it "does not mark the original model as deleted" do
          model = UserComplianceInfo.find(@model_id)
          expect(model).not_to be_deleted
        end
      end
    end
  end
end
