# frozen_string_literal: true

require "spec_helper"

describe Api::V2::FilesController do
  let(:user) { create(:user) }
  let(:app) { create(:oauth_application, owner: create(:user)) }

  describe "POST 'presign'" do
    let(:action) { :presign }
    let(:params) { { filename: "course.pdf", file_size: 1024 * 1024 } }

    before do
      allow_any_instance_of(Aws::S3::Client).to receive(:create_multipart_upload)
        .and_return(double(upload_id: "test-upload-id"))
    end

    context "without a token" do
      it "returns 401" do
        post action, params: params
        expect(response.status).to eq(401)
      end
    end

    context "with a token missing edit_products scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "view_public view_sales") }
      let(:params) { super().merge(access_token: token.token) }

      it "returns 403" do
        post action, params: params
        expect(response.status).to eq(403)
      end
    end

    context "with edit_products scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_products") }
      let(:params) { super().merge(access_token: token.token) }

      it "returns success with upload_id, key, file_url, and parts" do
        post action, params: params
        body = response.parsed_body
        expect(body["success"]).to be true
        expect(body["upload_id"]).to eq("test-upload-id")
        expect(body["key"]).to be_present
        expect(body["file_url"]).to be_present
        expect(body["parts"]).to be_an(Array)
        expect(body["parts"].first).to include("part_number", "presigned_url")
      end

      it "includes the user external_id and filename in the key and file_url" do
        post action, params: params
        body = response.parsed_body
        expect(body["key"]).to include(user.external_id)
        expect(body["key"]).to include("course.pdf")
        expect(body["key"]).to match(%r{attachments/.+/.+/original/course\.pdf})
        expect(body["file_url"]).to include(user.external_id)
        expect(body["file_url"]).to include("course.pdf")
      end

      it "returns 1 part for files at or below part size" do
        post action, params: params.merge(file_size: 1024)
        expect(response.parsed_body["parts"].count).to eq(1)
      end

      it "returns multiple parts for large files" do
        post action, params: params.merge(file_size: 250 * 1024 * 1024) # 250 MB → 3 parts
        expect(response.parsed_body["parts"].count).to eq(3)
      end

      it "part numbers are sequential starting at 1" do
        post action, params: params.merge(file_size: 200 * 1024 * 1024) # 2 parts
        part_numbers = response.parsed_body["parts"].map { |p| p["part_number"] }
        expect(part_numbers).to eq([1, 2])
      end

      it "returns 400 when filename is missing" do
        post action, params: params.except(:filename)
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to be_present
      end

      it "returns 400 when file_size is missing" do
        post action, params: params.except(:file_size)
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to be_present
      end

      it "returns 400 when file_size is sent as a file upload" do
        post action, params: params.merge(file_size: fixture_file_upload("blah.txt", "text/plain"))
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to eq("file_size is required")
      end

      it "returns 400 when S3 raises a service error" do
        allow_any_instance_of(Aws::S3::Client).to receive(:create_multipart_upload)
          .and_raise(Aws::S3::Errors::ServiceError.new(nil, "S3 unavailable"))
        post action, params: params
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to include("S3 unavailable")
      end

      it "returns 400 when file_size exceeds the 20 GB maximum" do
        post action, params: params.merge(file_size: 21 * 1024 * 1024 * 1024)
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to include("20 GB")
      end
    end

    context "with account scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "account") }
      let(:params) { super().merge(access_token: token.token) }

      it "returns success" do
        post action, params: params
        expect(response.parsed_body["success"]).to be true
      end
    end
  end

  describe "POST 'complete'" do
    let(:key) { "attachments/#{user.external_id}/abc123hex/original/course.pdf" }
    let(:action) { :complete }
    let(:params) do
      {
        upload_id: "test-upload-id",
        key: key,
        parts: [{ part_number: 1, etag: '"etag-abc"' }]
      }
    end

    before do
      allow_any_instance_of(Aws::S3::Client).to receive(:complete_multipart_upload)
    end

    context "without a token" do
      it "returns 401" do
        post action, params: params
        expect(response.status).to eq(401)
      end
    end

    context "with edit_products scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_products") }
      let(:params) { super().merge(access_token: token.token) }

      it "returns success with file_url" do
        post action, params: params
        body = response.parsed_body
        expect(body["success"]).to be true
        expect(body["file_url"]).to include(key)
      end

      it "returns 400 when upload_id is missing" do
        post action, params: params.except(:upload_id)
        expect(response.status).to eq(400)
      end

      it "returns 400 when key is missing" do
        post action, params: params.except(:key)
        expect(response.status).to eq(400)
      end

      it "returns 400 when parts is missing" do
        post action, params: params.except(:parts)
        expect(response.status).to eq(400)
      end

      it "returns 400 for a key scoped to a different user" do
        post action, params: params.merge(key: "attachments/other-user-id/abc/original/file.pdf")
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to eq("invalid key")
      end

      it "returns 400 when S3 raises a service error" do
        allow_any_instance_of(Aws::S3::Client).to receive(:complete_multipart_upload)
          .and_raise(Aws::S3::Errors::ServiceError.new(nil, "boom"))
        post action, params: params
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to include("boom")
      end

      it "returns 400 with the S3 error message when the upload_id no longer exists" do
        allow_any_instance_of(Aws::S3::Client).to receive(:complete_multipart_upload)
          .and_raise(Aws::S3::Errors::NoSuchUpload.new(nil, "The specified upload does not exist."))
        post action, params: params
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to include("does not exist")
      end
    end

    context "with account scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "account") }
      let(:params) { super().merge(access_token: token.token) }

      it "returns success" do
        post action, params: params
        expect(response.parsed_body["success"]).to be true
        expect(response.parsed_body["file_url"]).to be_present
      end
    end
  end

  describe "POST 'abort'" do
    let(:key) { "attachments/#{user.external_id}/abc123hex/original/course.pdf" }
    let(:action) { :abort }
    let(:params) { { upload_id: "test-upload-id", key: key } }

    before do
      allow_any_instance_of(Aws::S3::Client).to receive(:abort_multipart_upload)
    end

    context "without a token" do
      it "returns 401" do
        post action, params: params
        expect(response.status).to eq(401)
      end
    end

    context "with a token missing edit_products scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "view_public view_sales") }
      let(:params) { super().merge(access_token: token.token) }

      it "returns 403" do
        post action, params: params
        expect(response.status).to eq(403)
      end
    end

    context "with edit_products scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "edit_products") }
      let(:params) { super().merge(access_token: token.token) }

      it "aborts the multipart upload and returns status=accepted" do
        expect_any_instance_of(Aws::S3::Client).to receive(:abort_multipart_upload)
          .with(bucket: S3_BUCKET, key: key, upload_id: "test-upload-id")
        post action, params: params
        body = response.parsed_body
        expect(response.status).to eq(200)
        expect(body["success"]).to be true
        expect(body["status"]).to eq("accepted")
      end

      it "returns 400 when upload_id is missing" do
        post action, params: params.except(:upload_id)
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to include("upload_id")
      end

      it "returns 400 when key is missing" do
        post action, params: params.except(:key)
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to include("key")
      end

      it "returns 400 for a key scoped to a different user" do
        post action, params: params.merge(key: "attachments/other-user-id/abc/original/file.pdf")
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to eq("invalid key")
      end

      it "returns 400 when S3 raises a service error" do
        allow_any_instance_of(Aws::S3::Client).to receive(:abort_multipart_upload)
          .and_raise(Aws::S3::Errors::ServiceError.new(nil, "boom"))
        post action, params: params
        expect(response.status).to eq(400)
        expect(response.parsed_body["error"]).to include("boom")
      end

      it "returns 200 with status=already_gone when S3 reports NoSuchUpload" do
        allow_any_instance_of(Aws::S3::Client).to receive(:abort_multipart_upload)
          .and_raise(Aws::S3::Errors::NoSuchUpload.new(nil, "The specified upload does not exist."))
        post action, params: params
        body = response.parsed_body
        expect(response.status).to eq(200)
        expect(body["success"]).to be true
        expect(body["status"]).to eq("already_gone")
      end
    end

    context "with account scope" do
      let(:token) { create("doorkeeper/access_token", application: app, resource_owner_id: user.id, scopes: "account") }
      let(:params) { super().merge(access_token: token.token) }

      it "returns success with status=accepted" do
        post action, params: params
        expect(response.parsed_body["success"]).to be true
        expect(response.parsed_body["status"]).to eq("accepted")
      end
    end
  end
end
