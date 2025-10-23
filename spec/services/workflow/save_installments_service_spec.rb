# frozen_string_literal: true

require "spec_helper"

describe Workflow::SaveInstallmentsService do
  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    stripe_connect_account = create(:merchant_account_stripe_connect, user: seller)
    create(:purchase, seller:, link: product, merchant_account: stripe_connect_account)
  end

  describe "#process" do
    let(:seller) { create(:user) }
    let(:preview_email_recipient) { seller }
    let(:product) { create(:product, user: seller) }
    let!(:workflow) { create(:workflow, seller:, link: product, workflow_type: Workflow::PRODUCT_TYPE) }
    let(:params) { { save_action_name: Workflow::SAVE_ACTION, send_to_past_customers: false, installments: [] } }
    let(:default_installment_params) do
      {
        name: "An email",
        message: "Lorem ipsum",
        time_duration: 1,
        time_period: "hour",
        send_preview_email: false,
        files: [],
      }
    end

    def process_and_perform_assertions_for_created_installments
      params[:installments] = [default_installment_params.merge(id: SecureRandom.uuid, files: [{ external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/file1.mp4", position: 1, stream_only: true, subtitle_files: [{ url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub1-uuid/en.srt", language: "English" }, { url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub2-uuid/es.srt", language: "Spanish" }] }, { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/file.pdf", position: 2, stream_only: false, subtitle_files: [] }])]
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect { service.process }.to change { workflow.installments.alive.count }.by(1)
      installment = workflow.installments.alive.last
      expect(installment.name).to eq("An email")
      expect(installment.message).to eq("Lorem ipsum")
      expect(installment.send_emails).to be(true)
      expect(installment.installment_type).to eq(workflow.workflow_type)
      expect(installment.json_data).to eq(workflow.json_data)
      expect(installment.seller_id).to eq(workflow.seller_id)
      expect(installment.link_id).to eq(workflow.link_id)
      expect(installment.base_variant_id).to eq(workflow.base_variant_id)
      expect(installment.is_for_new_customers_of_workflow).to eq(!workflow.send_to_past_customers)
      expect(installment.published_at).to eq(workflow.published_at)
      expect(installment.workflow_installment_published_once_already).to eq(workflow.first_published_at.present?)
      expect(installment.installment_rule.delayed_delivery_time).to eq(1.hour.to_i)
      expect(installment.installment_rule.time_period).to eq("hour")
      expect(installment.alive_product_files.count).to eq(2)
      file1 = installment.alive_product_files.first
      expect(file1.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/file1.mp4")
      expect(file1.position).to eq(1)
      expect(file1.stream_only).to be(true)
      expect(file1.filegroup).to eq("video")
      expect(file1.subtitle_files.alive.pluck(:language, :url)).to eq([["English", "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub1-uuid/en.srt"], ["Spanish", "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub2-uuid/es.srt"]])
      file2 = installment.alive_product_files.last
      expect(file2.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/file.pdf")
      expect(file2.position).to eq(2)
      expect(file2.stream_only).to be(false)
      expect(file2.filegroup).to eq("document")
    end

    def process_and_perform_assertions_for_updated_installments
      installment = create(:workflow_installment, seller:, link: product, workflow:, name: "Installment 1", message: "Message 1")
      video = create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/video.mp", link: nil, position: 1, stream_only: true)
      video.subtitle_files << create(:subtitle_file, product_file: video, language: "English", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub1-uuid/en.srt")
      video.subtitle_files << create(:subtitle_file, product_file: video, language: "Spanish", url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub2-uuid/es.srt")
      pdf = create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/doc.pdf", link: nil, position: 2, stream_only: false)
      audio = create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/audio.mp3", link: nil, position: 3, stream_only: false)
      params[:installments] = [default_installment_params.merge(id: installment.external_id, name: "Installment 1 (edited)", message: "Updated message", time_duration: 2, time_period: "day", files: [{ external_id: video.external_id, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/video.mp4", position: 1, stream_only: true, subtitle_files: [{ url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub1-uuid/en.srt", language: "English" }, { url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub2-uuid/es.srt", language: "German" }] }, { external_id: pdf.external_id, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/doc.pdf", position: 2, stream_only: false, subtitle_files: [] }, { external_id: SecureRandom.uuid, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.epub", position: 3, stream_only: false, subtitle_files: [] }])]
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect { service.process }.to change { workflow.installments.alive.count }.by(0)
      expect(installment.reload.name).to eq("Installment 1 (edited)")
      expect(installment.message).to eq("Updated message")
      expect(installment.send_emails).to be(true)
      expect(installment.installment_type).to eq(workflow.workflow_type)
      expect(installment.json_data).to eq(workflow.json_data)
      expect(installment.seller_id).to eq(workflow.seller_id)
      expect(installment.link_id).to eq(workflow.link_id)
      expect(installment.base_variant_id).to eq(workflow.base_variant_id)
      expect(installment.is_for_new_customers_of_workflow).to eq(!workflow.send_to_past_customers)
      expect(installment.published_at).to eq(workflow.published_at)
      expect(installment.workflow_installment_published_once_already).to eq(workflow.first_published_at.present?)
      expect(installment.installment_rule.delayed_delivery_time).to eq(2.days.to_i)
      expect(installment.installment_rule.time_period).to eq("day")
      expect(installment.alive_product_files.count).to eq(3)
      file1 = installment.alive_product_files.first
      expect(file1.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/video.mp4")
      expect(file1.position).to eq(1)
      expect(file1.stream_only).to be(true)
      expect(file1.filegroup).to eq("video")
      expect(file1.subtitle_files.alive.pluck(:language, :url)).to eq([["English", "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub1-uuid/en.srt"], ["German", "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/sub2-uuid/es.srt"]])
      file2 = installment.alive_product_files.second
      expect(file2.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/doc.pdf")
      expect(file2.position).to eq(2)
      expect(file2.stream_only).to be(false)
      expect(file2.filegroup).to eq("document")
      file3 = installment.alive_product_files.last
      expect(file3.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/book.epub")
      expect(file3.position).to eq(3)
      expect(file3.stream_only).to be(false)
      expect(file3.filegroup).to eq("document")
      expect(audio.reload.alive?).to be(false)
    end

    describe "for an abandoned cart workflow" do
      let!(:workflow) { create(:workflow, seller:, link: product, workflow_type: Workflow::ABANDONED_CART_TYPE) }

      it "returns an error when the number of saved installments are zero" do
        params[:installments] = []

        service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
        expect do
          success, error = service.process

          expect(success).to be(false)
          expect(error).to eq("An abandoned cart workflow can only have one email.")
        end.to_not change { workflow.installments.alive.count }
      end

      it "returns an error while saving more than one installment" do
        params[:installments] = [default_installment_params, default_installment_params]

        service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
        expect do
          success, error = service.process

          expect(success).to be(false)
          expect(error).to eq("An abandoned cart workflow can only have one email.")
        end.to_not change { workflow.installments.alive.count }
      end

      it "saves only one installment" do
        params[:installments] = [default_installment_params.merge(message: "Lorem ipsum<product-list-placeholder></product-list-placeholder>")]

        service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
        expect do
          success, error = service.process

          expect(success).to be(true)
          expect(error).to be_nil
        end.to change { workflow.installments.alive.count }.by(1)

        installment = workflow.installments.alive.last
        expect(installment.message).to eq("Lorem ipsum<product-list-placeholder></product-list-placeholder>")
      end

      it "appends the <product-list-placeholder /> tag to the message if it's missing" do
        params[:installments] = [default_installment_params.merge(message: "Lorem ipsum")]

        service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
        expect do
          service.process
        end.to change { workflow.installments.alive.count }.by(1)

        installment = workflow.installments.alive.last
        expect(installment.message).to eq("Lorem ipsum<product-list-placeholder></product-list-placeholder>")
      end
    end

    it "creates installments" do
      expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

      process_and_perform_assertions_for_created_installments
    end

    it "creates installments and publishes them if save_action_name is 'save_and_publish'" do
      params[:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

      expect_any_instance_of(Workflow).to receive(:schedule_installment).with(kind_of(Installment))

      expect do
        process_and_perform_assertions_for_created_installments
      end.to change { workflow.reload.published_at }.from(nil).to(kind_of(Time))
         .and change { workflow.first_published_at }.from(nil).to(kind_of(Time))
         .and change { workflow.installments.alive.pluck(:published_at).uniq }.from([]).to([kind_of(Time)])
    end

    it "updates installments" do
      expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

      process_and_perform_assertions_for_updated_installments
    end

    it "updates installments and publishes them if save_action_name is 'save_and_publish'" do
      params[:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

      expect_any_instance_of(Workflow).to receive(:schedule_installment).with(kind_of(Installment))

      expect do
        process_and_perform_assertions_for_updated_installments
      end.to change { workflow.reload.published_at }.from(nil).to(kind_of(Time))
         .and change { workflow.first_published_at }.from(nil).to(kind_of(Time))

      expect(workflow.installments.alive.pluck(:published_at).uniq).to eq([workflow.published_at])
    end

    it "updates installments and unpublishes them if save_action_name is 'save_and_unpublish'" do
      workflow.publish!

      params[:save_action_name] = Workflow::SAVE_AND_UNPUBLISH_ACTION

      expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

      expect do
        expect do
          process_and_perform_assertions_for_updated_installments
        end.to change { workflow.reload.published_at }.from(kind_of(Time)).to(nil)
      end.not_to change { workflow.first_published_at }

      expect(workflow.installments.alive.pluck(:published_at).uniq).to eq([nil])
    end

    context "when delayed_delivery_time changes" do
      let(:installment) { create(:installment, workflow:, name: "Installment 1", message: "Message 1") }
      let!(:installment_rule) { create(:installment_rule, installment:, delayed_delivery_time: 1.hour.to_i, time_period: "hour") }

      context "when installment has been published" do
        before do
          workflow.update!(published_at: Time.current)
          installment.update!(published_at: workflow.published_at)
        end

        it "reschedules that installment" do
          expect(SendWorkflowPostEmailsJob).to receive(:perform_async).with(installment.id, installment.published_at.iso8601)

          params[:installments] = [default_installment_params.merge(id: installment.external_id, time_duration: 2, time_period: "day")]
          service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

          expect do
            service.process
          end.to change { installment.reload.installment_rule.delayed_delivery_time }.from(1.hour.to_i).to(2.days.to_i)
             .and change { installment.reload.installment_rule.time_period }.from("hour").to("day")
        end

        it "does not reschedule that installment if save_action_name is other than 'save'" do
          expect(SendWorkflowPostEmailsJob).not_to receive(:perform_async)
          expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

          params[:installments] = [default_installment_params.merge(id: installment.external_id, time_duration: 2, time_period: "day", send_preview_email: true)]
          params[:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

          service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

          expect do
            service.process
          end.to change { installment.reload.installment_rule.delayed_delivery_time }.from(1.hour.to_i).to(2.days.to_i)
             .and change { installment.reload.installment_rule.time_period }.from("hour").to("day")
        end
      end

      context "when installment has not been published" do
        it "does not reschedule that installment" do
          expect(SendWorkflowPostEmailsJob).not_to receive(:perform_async)

          params[:installments] = [default_installment_params.merge(id: installment.external_id, time_duration: 2, time_period: "day")]
          service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

          expect do
            service.process
          end.to change { installment.reload.installment_rule.delayed_delivery_time }.from(1.hour.to_i).to(2.days.to_i)
             .and change { installment.reload.installment_rule.time_period }.from("hour").to("day")
        end
      end
    end

    it "reschedules a newly added installment if the workflow is already published" do
      workflow.publish!

      expect_any_instance_of(Workflow).to receive(:schedule_installment).with(kind_of(Installment), old_delayed_delivery_time: nil)

      params[:installments] = [default_installment_params.merge(id: SecureRandom.uuid, time_duration: 1, time_period: "hour")]
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

      expect do
        service.process
      end.to change { workflow.installments.alive.count }.by(1)

      installment = workflow.installments.alive.last
      expect(installment.installment_rule.delayed_delivery_time).to eq(1.hour.to_i)
      expect(installment.installment_rule.time_period).to eq("hour")
      expect(installment.published_at).to eq(workflow.published_at)
    end

    it "does not reschedule an installment if the delayed_delivery_time does not change" do
      expect(SendWorkflowPostEmailsJob).not_to receive(:perform_async)

      installment = create(:installment, workflow:)
      create(:installment_rule, installment:, delayed_delivery_time: 1.hour.to_i, time_period: "hour")
      params[:installments] = [default_installment_params.merge(id: installment.external_id, time_duration: 1, time_period: "hour")]
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

      expect do
        service.process
      end.not_to change { installment.reload.installment_rule.delayed_delivery_time }
    end

    it "deletes installments that are missing from the params" do
      installment = create(:installment, workflow:)
      attached_file = create(:product_file, installment:, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/doc.pdf", link: nil)
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect { service.process }.to change { workflow.installments.alive.count }.by(-1)
      expect(installment.reload.deleted_at).to be_present

      # But keeps the attached file alive
      expect(attached_file.reload.alive?).to be(true)
    end

    it "updates the 'send_to_past_customers' flag only if the workflow is yet to be published" do
      # If the workflow is yet to be published, the 'send_to_past_customers' flag is updated
      params[:send_to_past_customers] = true
      params[:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect { service.process }.to change { workflow.reload.send_to_past_customers }.from(false).to(true)

      # Since the workflow is already published, the 'send_to_past_customers' flag will be ignored afterwards
      params[:send_to_past_customers] = false
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect { service.process }.not_to change { workflow.reload.send_to_past_customers }
    end

    it "maintains a mapping of old and new installment ids" do
      installment1 = create(:installment, workflow:, name: "Installment 1", message: "Message 1")
      create(:installment, workflow:, name: "Installment 2", message: "Message 2")
      new_installment_temporary_id = SecureRandom.uuid
      params[:installments] = [ActionController::Parameters.new(id: installment1.external_id, name: "Installment 1 (edited)", message: "Updated message"), ActionController::Parameters.new(id: new_installment_temporary_id, name: "Installment 3", message: "Message 3")]
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect { service.process }.to change { workflow.installments.alive.count }.by(0)
                                .and change { workflow.installments.count }.by(1)
      expect(service.old_and_new_installment_id_mapping).to eq(
        installment1.external_id => installment1.external_id,
        new_installment_temporary_id => workflow.installments.last.external_id
      )
    end

    it "does not save installments if there are errors" do
      params[:installments] = [default_installment_params.merge(id: SecureRandom.uuid, message: "")]
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect do
        expect(service.process).to eq([false, "Please include a message as part of the update."])
      end.to_not change { workflow.installments.alive.count }
      expect(service.error).to eq("Please include a message as part of the update.")
    end

    it "does not save installments while publishing if the seller's email is not confirmed" do
      seller.update!(confirmed_at: nil)
      installment = create(:workflow_installment, seller:, link: product, workflow:, name: "Installment 1", message: "Message 1")
      params[:installments] = [
        default_installment_params.merge(id: installment.external_id, name: "Installment 1 (edited)", message: "Updated message", time_duration: 2, time_period: "day", files: []),
        default_installment_params.merge(id: SecureRandom.uuid, message: "Test")
      ]
      params[:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
      expect do
        expect(service.process).to eq([false, "You have to confirm your email address before you can do that."])
      end.not_to change { workflow.reload.published_at }
      expect(workflow.installments.alive.sole.id).to eq(installment.id)
      expect(installment.reload.name).to eq("Installment 1")
    end

    describe "email preview" do
      context "for an abandoned cart workflow" do
        let(:workflow) { create(:abandoned_cart_workflow, seller:) }

        it "sends preview email" do
          installment = workflow.installments.alive.first
          params[:installments] = [default_installment_params.merge(id: installment.external_id, name: "Updated name", message: "Updated description<product-list-placeholder></product-list-placeholder>", send_preview_email: true)]
          service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)
          expect do
            service.process
          end.to change { installment.reload.name }.from("You left something in your cart").to("Updated name")
         .and change { installment.message }.from("When you're ready to buy, complete checking out.<product-list-placeholder />Thanks!").to("Updated description<product-list-placeholder></product-list-placeholder>")
         .and have_enqueued_mail(CustomerMailer, :abandoned_cart_preview).with(seller.id, installment.id)
        end
      end

      context "for a non-abandoned cart workflow" do
        it "sends preview email" do
          expect(PostSendgridApi).to receive(:process).with(post: an_instance_of(Installment), recipients: [{ email: preview_email_recipient.email }], preview: true)

          installment = create(:installment, workflow:)
          params[:installments] = [default_installment_params.merge(id: installment.external_id, name: "Updated name", send_preview_email: true)]
          service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

          expect { service.process }.to change { installment.reload.name }.from(installment.name).to("Updated name")
        end
      end

      it "does not send preview email if the reciepient hasn't confirmed their email address yet" do
        expect(PostSendgridApi).not_to receive(:process)

        installment = create(:installment, workflow:)
        preview_email_recipient.update!(email: "new@example.com")
        params[:installments] = [default_installment_params.merge(id: installment.external_id, name: "Updated name", send_preview_email: true)]
        service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

        expect { service.process }.to_not change { installment.reload.name }
        expect(service.error).to eq("You have to confirm your email address before you can do that.")
      end

      it "does not send preview email if send_preview_email is false" do
        expect(PostSendgridApi).not_to receive(:process)

        installment = create(:installment, workflow:)
        params[:installments] = [default_installment_params.merge(id: installment.external_id, name: "Updated name", send_preview_email: false)]
        service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

        expect { service.process }.to change { installment.reload.name }.from(installment.name).to("Updated name")
      end
    end

    it "processes upsell cards in the installment message" do
      product = create(:product, user: seller, price_cents: 1000)
      message_with_upsell = %(<p>Check out this product:</p><upsell-card productid="#{product.external_id}" discount='{"type":"fixed","cents":500}'></upsell-card>)

      params[:installments] = [default_installment_params.merge(id: SecureRandom.uuid, message: message_with_upsell)]
      service = described_class.new(seller:, params:, workflow:, preview_email_recipient:)

      expect { service.process }.to change { Upsell.count }.by(1)
                               .and change { OfferCode.count }.by(1)
                               .and change { workflow.installments.alive.count }.by(1)

      installment = workflow.installments.alive.last
      expect(installment.message).to include("<upsell-card")

      upsell = Upsell.last
      expect(installment.message).to include("id=\"#{upsell.external_id}\"")
    end
  end
end
