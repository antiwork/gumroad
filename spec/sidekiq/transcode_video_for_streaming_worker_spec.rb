# frozen_string_literal: true

describe TranscodeVideoForStreamingWorker do
  describe "#perform" do
    let(:product) { create(:product_with_video_file) }

    context "when the product file is not transcodable" do
      let(:product_file) { product.product_files.first }

      it "notifies the creator and does not create a transcoding job" do
        expect(product_file.transcodable?).to be(false)

        expect do
          described_class.new.perform(product_file.id)
        end
          .to change { TranscodedVideo.count }.by(0)
          .and have_enqueued_mail(ContactingCreatorMailer, :video_transcode_failed).with(product_file.id)
      end

      it "does nothing if `#attempt_to_transcode?` returns `false`" do
        create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "completed")
        expect(ContactingCreatorMailer).to_not receive(:video_transcode_failed)

        expect(product_file.transcodable?).to be(false)
        expect(product_file.attempt_to_transcode?).to be(false)

        expect do
          described_class.new.perform(product_file.id)
        end.to_not change { TranscodedVideo.count }
      end
    end

    context "when the product file is transcodable" do
      let(:product_file) do
        product_file = product.product_files.first
        product_file.update!(width: 854, height: 480)
        product_file
      end

      before do
        expect(product_file.transcodable?).to be(true)

        mediaconvert_client_double = double("mediaconvert_client")
        allow(mediaconvert_client_double).to receive(:job).and_return(OpenStruct.new({ id: "abc-123" }))
        allow_any_instance_of(Aws::MediaConvert::Client).to receive(:create_job).and_return(mediaconvert_client_double)
      end

      it "does nothing when the product file is deleted" do
        product_file.delete!

        expect do
          described_class.new.perform(product_file.id)
        end.to_not change { TranscodedVideo.count }
      end

      it "creates a transcoded_video record and marks it as completed if there's already another duplicate completed one" do
        completed_transcode = create(:transcoded_video, original_video_key: product_file.s3_key, transcoded_video_key: product_file.s3_key + ".transcoded", state: "completed")
        expect_any_instance_of(Aws::MediaConvert::Client).not_to receive(:create_job)

        expect do
          described_class.new.perform(product_file.id)
        end.to change { TranscodedVideo.count }.by(1)

        transcoded_video = TranscodedVideo.last!
        expect(transcoded_video.original_video_key).to eq(completed_transcode.original_video_key)
        expect(transcoded_video.transcoded_video_key).to eq(completed_transcode.transcoded_video_key)
      end

      it "creates a transcoded_video but doesn't process it if there's already another duplicate processing one" do
        processing_transcode = create(:transcoded_video, original_video_key: product_file.s3_key, transcoded_video_key: product_file.s3_key + ".transcoded", state: "processing")
        expect_any_instance_of(Aws::MediaConvert::Client).not_to receive(:create_job)

        expect do
          described_class.new.perform(product_file.id)
        end.to change { TranscodedVideo.count }.by(1)

        transcoded_video = TranscodedVideo.last!
        expect(transcoded_video.original_video_key).to eq(processing_transcode.original_video_key)
        expect(transcoded_video.streamable).to eq(product_file)
      end

      it "transcodes the video and does not send the transcoding error email", :vcr do
        expect(ContactingCreatorMailer).to_not receive(:video_transcode_failed)

        expect do
          described_class.new.perform(product_file.id)
        end.to change { TranscodedVideo.count }.by(1)
      end

      it "does nothing if `#attempt_to_transcode?` returns `false`" do
        create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "completed")
        expect(ContactingCreatorMailer).to_not receive(:video_transcode_failed)

        expect(product_file.attempt_to_transcode?).to be(false)

        expect do
          described_class.new.perform(product_file.id)
        end.to_not change { TranscodedVideo.count }
      end

      it "marks the existing transcoded video still processing as failed, when `allowed_when_processing` is true" do
        transcoded_video = create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "processing")

        expect_any_instance_of(Aws::MediaConvert::Client).to receive(:create_job)

        expect do
          described_class.new.perform(product_file.id, ProductFile.name, "mediaconvert", true)
        end.to change { TranscodedVideo.count }

        expect(transcoded_video.reload.state).to eq("error")
      end

      it "does not mark the existing transcoded video still processing as failed, when `allowed_when_processing` is false" do
        transcoded_video = create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "processing")

        expect do
          described_class.new.perform(product_file.id)
        end.to_not change { TranscodedVideo.count }

        expect(transcoded_video.reload.state).to eq("processing")
      end

      it "transcodes the video when input video key is more than 255 bytes long", :vcr do
        product_file.update!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/Identify+Relevant+important+FB+Groups+(Not+just+your+FB+Page)+of+your+geographical+location+area+and+post+OFFERS%2C+social+media+posts+there+also+to+get+Branding+%26+Visibility+%2B+more+likes+on+FB+Page+and+to+get+some+more+traction+from+your+audience+without+much+of+a+hassle.mov")

        expect do
          expect do
            described_class.new.perform(product_file.id)
          end.to_not raise_error
        end.to change { TranscodedVideo.count }.by(1)

        expect(TranscodedVideo.last.original_video_key).to eq(product_file.s3_key)
        expect(TranscodedVideo.last.transcoded_video_key).to eq("specs/Identify+Relevant+important+FB+Groups+(Not+just+your+FB+Page)+of+your+geographical+location+area+and+post+OFFERS%2C+social+media+posts+there+also+to+get+Branding+%26+Visibility+%2B+more+likes+on+FB+Page+and+to+get+some+more+traction+from+your+audience+without+much+of+a+hassle/hls/")
      end

      describe "transcode using MediaConvert" do
        before do
          product_file.update!(height: 1080)

          @mediaconvert_job_params = {
            queue: MEDIACONVERT_QUEUE,
            role: MEDIACONVERT_ROLE,
            settings: {
              output_groups: [
                {
                  name: "Apple HLS",
                  output_group_settings: {
                    type: "HLS_GROUP_SETTINGS",
                    hls_group_settings: {
                      segment_length: 10,
                      min_segment_length: 0,
                      destination: "s3://#{S3_BUCKET}/specs/ScreenRecording/hls/index",
                      destination_settings: {
                        s3_settings: {
                          access_control: {
                            canned_acl: "PUBLIC_READ"
                          }
                        }
                      }
                    }
                  },
                  outputs: [
                    {
                      preset: "hls_480p",
                      name_modifier: "_480p"
                    },
                    {
                      preset: "hls_1080p",
                      name_modifier: "_1080p"
                    }
                  ]
                }
              ],
              inputs: [
                {
                  audio_selectors: {
                    "Audio Selector 1": {
                      default_selection: "DEFAULT"
                    }
                  },
                  video_selector: {
                    rotate: "AUTO"
                  },
                  file_input: "s3://#{S3_BUCKET}/specs/ScreenRecording.mov"
                }
              ]
            },
            acceleration_settings: {
              mode: "DISABLED"
            }
          }
        end

        it "creates MediaConvert job and a TranscodedVideo object" do
          expect_any_instance_of(Aws::MediaConvert::Client).to receive(:create_job).with(@mediaconvert_job_params)

          expect do
            described_class.new.perform(product_file.id)
          end.to change { TranscodedVideo.count }.by(1)

          expect(TranscodedVideo.last.job_id).to eq "abc-123"
          expect(TranscodedVideo.last.transcoded_video_key).to eq "specs/ScreenRecording/hls/"
        end

        context "with GRMC", :freeze_time do
          before do
            allow(GlobalConfig).to receive(:get).with("GRMC_API_KEY").and_return("test_api_key")
          end

          context "when request to GRMC is successful" do
            before do
              stub_request(:post, described_class::GRMC_ENDPOINT)
                .to_return(status: 200, body: { job_id: "grmc-123" }.to_json, headers: { "Content-Type" => "application/json" })
            end

            it "creates a GRMC job, a TranscodedVideo object, and schedules a retry with AWS MediaConvert" do
              expect_any_instance_of(Aws::MediaConvert::Client).not_to receive(:create_job)

              expect do
                described_class.new.perform(product_file.id)
              end.to change { TranscodedVideo.count }.by(1)

              transcoded_video = TranscodedVideo.last!
              expect(transcoded_video.job_id).to eq "grmc-123"
              expect(transcoded_video.transcoded_video_key).to eq "specs/ScreenRecording/hls/"
              expect(transcoded_video.via_grmc).to be(true)
              expect(transcoded_video.streamable).to eq(product_file)

              expect(described_class).to have_enqueued_sidekiq_job(product_file.id, ProductFile.name, described_class::MEDIACONVERT, true).in(24.hours)
            end
          end

          context "when request to GRMC is not successful" do
            before do
              stub_request(:post, described_class::GRMC_ENDPOINT)
                .to_return(status: 429)
            end

            it "creates MediaConvert job and a TranscodedVideo object" do
              expect_any_instance_of(Aws::MediaConvert::Client).to receive(:create_job).with(@mediaconvert_job_params)

              expect do
                described_class.new.perform(product_file.id)
              end.to change { TranscodedVideo.count }.by(1)

              transcoded_video = TranscodedVideo.last!
              expect(transcoded_video.job_id).to eq "abc-123"
              expect(transcoded_video.transcoded_video_key).to eq "specs/ScreenRecording/hls/"
              expect(transcoded_video.via_grmc).to be(false)
              expect(transcoded_video.streamable).to eq(product_file)
            end
          end
        end

        it "transcodes the video and does not send the transcoding error email", :vcr do
          expect(ContactingCreatorMailer).to_not receive(:video_transcode_failed)

          expect do
            described_class.new.perform(product_file.id)
          end.to change { TranscodedVideo.count }.by(1)
        end

        it "does nothing if `#attempt_to_transcode?` returns `false`" do
          create(:transcoded_video, streamable: product_file, original_video_key: product_file.s3_key, state: "completed")
          expect(ContactingCreatorMailer).to_not receive(:video_transcode_failed)

          expect(product_file.attempt_to_transcode?).to be(false)

          expect do
            described_class.new.perform(product_file.id)
          end.to_not change { TranscodedVideo.count }
        end

        context "when transcoder param is set to ets" do
          before do
            ets_client_double = double("ets_client")
            allow(ets_client_double).to receive(:data).and_return(OpenStruct.new({ job: { id: 1 } }))
            allow_any_instance_of(Aws::ElasticTranscoder::Client).to receive(:create_job).and_return(ets_client_double)
          end

          it "transcodes the video using ETS" do
            expect_any_instance_of(Aws::ElasticTranscoder::Client).to receive(:create_job)

            ets_transcoder = described_class::ETS
            described_class.new.perform(product_file.id, ProductFile.name, ets_transcoder)
          end
        end

        context "when transcoder param is set to MediaConvert" do
          it "transcodes the video using MediaConvert" do
            expect_any_instance_of(Aws::MediaConvert::Client).to receive(:create_job)

            mediaconvert = described_class::MEDIACONVERT
            described_class.new.perform(product_file.id, ProductFile.name, mediaconvert)
          end
        end
      end
    end

    describe "transcode using ETS" do
      let(:product_file) { product.product_files.first }

      describe "output_key_prefix" do
        before do
          ets_client_double = double("ets_client")
          allow(ets_client_double).to receive(:data).and_return(OpenStruct.new({ job: { id: 1 } }))
          allow_any_instance_of(Aws::ElasticTranscoder::Client).to receive(:create_job).and_return(ets_client_double)
          @ets_transcoder = described_class::ETS
        end

        context "when repeated occurrences of extension is present in the filename" do
          it "generates the correct output_key_prefix" do
            original_video_key = "prefix/original/Ep 1.mp4 1-6 slides test.mp4 1-6 slides test.mp4 1-6 slides test.mp4"

            output_prefix_key = "prefix/original/Ep 1.mp4 1-6 slides test.mp4 1-6 slides test.mp4 1-6 slides test/hls/"
            expect_any_instance_of(Aws::ElasticTranscoder::Client).to receive(:create_job).with(hash_including({ output_key_prefix: output_prefix_key }))

            described_class.new.create_hls_transcode_job(product_file, original_video_key, 1080, @ets_transcoder)
          end

          it "generates the correct output_key_prefix when filename contains multiple lines" do
            original_video_key = "prefix/original/Ep 1.mp4 1-6 slides test.mp4\n 1-6 slides test.mp4\n 1-6 slides test.mp4"

            output_prefix_key = "prefix/original/Ep 1.mp4 1-6 slides test.mp4\n 1-6 slides test.mp4\n 1-6 slides test/hls/"
            expect_any_instance_of(Aws::ElasticTranscoder::Client).to receive(:create_job).with(hash_including({ output_key_prefix: output_prefix_key }))

            described_class.new.create_hls_transcode_job(product_file, original_video_key, 1080, @ets_transcoder)
          end
        end

        context "when repeated occurrences of extension is not present in the filename" do
          it "generates the correct output_key_prefix" do
            original_video_key = "prefix/original/test.mp4"

            output_prefix_key = "prefix/original/test/hls/"
            expect_any_instance_of(Aws::ElasticTranscoder::Client).to receive(:create_job).with(hash_including({ output_key_prefix: output_prefix_key }))

            described_class.new.create_hls_transcode_job(product_file, original_video_key, 1080, @ets_transcoder)
          end
        end
      end
    end
  end
end
