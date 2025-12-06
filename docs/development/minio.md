# MinIO for Local Development

## Overview

Gumroad uses MinIO in development to emulate AWS S3 without requiring paid AWS credentials. MinIO is an S3-compatible object storage server that runs in Docker.

## Configuration

### Environment Variables

Set in `.env.development`:

```bash
AWS_S3_ENDPOINT=https://minio.gumroad.dev
AWS_ACCESS_KEY_ID=minioadmin
AWS_SECRET_ACCESS_KEY=minioadmin
S3_DELETER_ACCESS_KEY_ID=minioadmin
S3_DELETER_SECRET_ACCESS_KEY=minioadmin
```

### Buckets

Auto-created by `docker-compose-local.yml`:

- **gumroad-dev**: Main development bucket
- **gumroad-dev-public-storage**: Public uploads
- **gumroad-specs**: Test fixtures
- **gumroad-invoices**: Invoice PDFs

### DNS

Add to `/etc/hosts`:

```
127.0.0.1 gumroad.dev
127.0.0.1 minio.gumroad.dev
```

## Usage

### Starting MinIO

```bash
make local
```

This starts all Docker services including MinIO.

### Accessing MinIO Console

1. Open http://localhost:9001
2. Login: `minioadmin` / `minioadmin`
3. View buckets, files, and settings

### Uploading Files

Files uploaded through the Rails app automatically go to MinIO:

```ruby
user = User.first
user.avatar.attach(
  io: File.open('path/to/image.jpg'),
  filename: 'avatar.jpg'
)
```

### Downloading Files

Files are served via presigned URLs:

```ruby
file = ProductFile.first
url = file.signed_url
```

## Troubleshooting

### Problem: "Access Denied" errors

Check MinIO is running:

```bash
docker ps | grep minio
```

Restart Docker services:

```bash
make stop_local && make local
```

Verify buckets exist:

```bash
docker exec -it web_minio_1 mc ls myminio
```

### Problem: SSL certificate errors

Regenerate certificates:

```bash
bin/generate_ssl_certificates
```

### Problem: Files not accessible

Make bucket public:

```bash
docker exec -it web_minio_1 mc anonymous set public myminio/gumroad-dev
```

### Problem: Want to use real AWS S3

1. Comment out `AWS_S3_ENDPOINT` in `.env.development`
2. Set real AWS credentials
3. Restart Rails: `bin/dev`

## How It Works

### Detection

`config/initializers/aws.rb`:

```ruby
USING_MINIO = AWS_S3_ENDPOINT.present? && !AWS_S3_ENDPOINT.include?("amazonaws.com")
```

### Path-Style URLs

MinIO requires path-style URLs: `https://endpoint/bucket/key`

Rails is configured with `force_path_style: true` for dev/test.

### Signed URLs

`app/helpers/signed_url_helper.rb` detects MinIO and uses S3 presigned URLs instead of CloudFront signed URLs.

### ActiveStorage

`config/storage.yml` defines the `development` service with MinIO support.

## Features That Don't Work with MinIO

These AWS-specific services require real AWS credentials:

- AWS MediaConvert: Video transcoding
- AWS Elastic Transcoder: HLS streaming
- CloudFront: CDN
- SSL Certificate Management: Production-only
- Custom Domain Verification: Production-only

For local development, these limitations are acceptable.

## Testing

Run specs with MinIO:

```bash
bundle exec rspec
bundle exec rspec spec/requests/products/edit/file_embeds_spec.rb
```

## Further Reading

- [MinIO Documentation](https://min.io/docs/minio/linux/index.html)
- [AWS S3 Compatibility](https://min.io/product/s3-compatibility)
- [Issue #1864](https://github.com/antiwork/gumroad/issues/1864)
- [PR #1773](https://github.com/antiwork/gumroad/pull/1773)
