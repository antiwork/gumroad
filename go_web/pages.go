package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

	"github.com/antiwork/gumroad/go_web/internal/delivery"
	"github.com/antiwork/gumroad/go_web/internal/downloads"
	"github.com/antiwork/gumroad/go_web/internal/flipper"
	"github.com/antiwork/gumroad/go_web/internal/inertia"
	"github.com/antiwork/gumroad/go_web/internal/obfuscate"
	"github.com/antiwork/gumroad/go_web/internal/pages"
	"github.com/antiwork/gumroad/go_web/internal/storage"
	"github.com/antiwork/gumroad/go_web/internal/vite"
	"github.com/antiwork/gumroad/go_web/internal/web"
)

// errPagesOff is a config that leaves full pages to Rails.
var errPagesOff = errors.New("full pages are off")

// pageConfig is what full pages need, or errPagesOff with the reason when something they
// read is missing. Only production's CDN_URL_MAP is ported.
func (d *dependencies) pageConfig(s3Client *s3.Client, ids *obfuscate.IDs) (*downloads.PageConfig, error) {
	env := d.env
	dir, cable := getenv("VITE_MANIFEST_DIR"), getenv("ANYCABLE_WEBSOCKET_URL")
	digestKey, dropboxKey := d.config("OBFUSCATE_IDS_CIPHER_KEY"), d.config("DROPBOX_PICKER_API_KEY")
	switch {
	case env.Name != "production":
		return nil, fmt.Errorf("%w: RAILS_ENV %s", errPagesOff, env.Name)
	case dir == "" || cable == "":
		return nil, fmt.Errorf("%w: VITE_MANIFEST_DIR or ANYCABLE_WEBSOCKET_URL is not set", errPagesOff)
	case digestKey == "" || dropboxKey == "":
		// Rails would render nil for these.
		return nil, fmt.Errorf("%w: OBFUSCATE_IDS_CIPHER_KEY or DROPBOX_PICKER_API_KEY is not set", errPagesOff)
	}
	manifest, err := vite.LoadDir(env.AssetHost(), dir)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errPagesOff, err)
	}
	layout, err := inertia.NewLayout(inertia.LayoutConfig{
		OGNamespace:    d.config("FACEBOOK_OG_NAMESPACE"),
		DNSPrefetch:    []string{env.AssetHost(), env.S3ProxyHost, env.PublicStorageHost},
		ActionCableURL: cable,
		Manifest:       manifest,
	})
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errPagesOff, err)
	}
	csp, err := web.NewCSP(env, d.globalConfig)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", errPagesOff, err)
	}
	conn, err := d.database()
	if err != nil {
		return nil, err
	}
	s3Endpoint := d.globalConfig("AWS_S3_ENDPOINT", "https://s3.amazonaws.com")
	return &downloads.PageConfig{
		Layout: layout,
		CSP:    csp,
		Shared: pages.NewShared(env, flipper.New(d.redis, "disable_stripe_signup").Active),
		Avatars: &storage.Avatars{
			DB:        conn,
			Exists:    s3Exister{client: s3Client, bucket: env.PublicStorageBucket},
			AssetHost: env.AssetHost(),
			// CDN_URL_MAP's https://<bucket>.s3.amazonaws.com/ => PUBLIC_STORAGE_CDN_S3_PROXY_HOST/.
			PublicCDN: env.PublicStorageHost + "/",
			Now:       time.Now,
			Logger:    d.logger,
		},
		Content: delivery.ContentConfig{
			IDs:       ids,
			S3BaseURL: d.globalConfig("S3_BASE_URL_TEMPLATE", s3Endpoint+"/gumroad/"),
			AssetHost: env.AssetHost(),
		},
		EmailDigestKey:  digestKey,
		DropboxAPIKey:   dropboxKey,
		IOSAppID:        d.globalConfig("IOS_APP_ID", "916819108"),
		AndroidBundleID: d.globalConfig("ANDROID_BUNDLE_ID", "com.gumroad.app"),
		NewNonce:        newNonce,
	}, nil
}

// globalConfig is GlobalConfig.get(name, default): a set variable wins even when empty,
// then a credential that is set, then the default.
func (d *dependencies) globalConfig(name, fallback string) string {
	if value, ok := lookupenv(name); ok {
		return value
	}
	if value, ok := d.credentials.Lookup(name); ok && value != "false" {
		return value
	}
	return fallback
}

// newNonce is SecureHeaders' SecureRandom.base64(32).
func newNonce() string {
	var b [32]byte
	rand.Read(b[:])
	return base64.StdEncoding.EncodeToString(b[:])
}

// s3ExistsTimeout bounds the presence check on the request path; a slow answer counts as
// present, as a failed one does in Rails.
const s3ExistsTimeout = time.Second

// s3Exister is S3Service#exist?: false only for a key S3 says isn't there.
type s3Exister struct {
	client *s3.Client
	bucket string
}

func (e s3Exister) Exists(ctx context.Context, key string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, s3ExistsTimeout)
	defer cancel()
	_, err := e.client.HeadObject(ctx, &s3.HeadObjectInput{Bucket: aws.String(e.bucket), Key: aws.String(key)},
		func(o *s3.Options) { o.RetryMaxAttempts = 1 })
	var notFound *types.NotFound
	if errors.As(err, &notFound) {
		return false, nil
	}
	return err == nil, err
}
