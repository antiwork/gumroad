package web

import (
	"fmt"
	"slices"
	"strings"
)

// Environment carries the config/domain.rb and config/initializers values the ported
// routes read. Keep each table in step with its Ruby source.
type Environment struct {
	Name     string
	Protocol string
	// DOMAIN and ROOT_DOMAIN.
	Domain     string
	RootDomain string
	// SHORT_DOMAIN, DISCOVER_DOMAIN, API_DOMAIN and THIRD_PARTY_ANALYTICS_DOMAIN.
	ShortDomain               string
	DiscoverDomain            string
	APIDomain                 string
	ThirdPartyAnalyticsDomain string
	ValidRequestHosts         []string
	ValidAPIRequestHosts      []string
	// PUBLIC_STORAGE_S3_BUCKET, PUBLIC_STORAGE_CDN_S3_PROXY_HOST and CDN_S3_PROXY_HOST.
	PublicStorageBucket string
	PublicStorageHost   string
	S3ProxyHost         string
	Revision            string
	// GR_NUM, sent as X-GR.
	GRNum string
	// ASSET_DOMAIN, and PageMeta::Base#default_page_title.
	AssetDomain string
	PageTitle   string

	requiresRevision bool
}

var environments = map[string]Environment{
	"production": {
		Protocol:                  "https",
		Domain:                    "gumroad.com",
		RootDomain:                "gumroad.com",
		ShortDomain:               "gum.co",
		DiscoverDomain:            "gumroad.com",
		APIDomain:                 "api.gumroad.com",
		ThirdPartyAnalyticsDomain: "gumroad-analytics.com",
		ValidRequestHosts:         []string{"gumroad.com", "app.gumroad.com"},
		ValidAPIRequestHosts:      []string{"api.gumroad.com"},
		PublicStorageBucket:       "gumroad-public-storage",
		PublicStorageHost:         "https://public-files.gumroad.com",
		S3ProxyHost:               "https://static-2.gumroad.com",
		AssetDomain:               "assets.gumroad.com",
		PageTitle:                 "Gumroad",
		requiresRevision:          true,
	},
	"staging": {
		Protocol:                  "https",
		Domain:                    "staging.gumroad.com",
		RootDomain:                "staging.gumroad.com",
		ShortDomain:               "staging.gum.co",
		DiscoverDomain:            "staging.gumroad.com",
		APIDomain:                 "api.staging.gumroad.com",
		ThirdPartyAnalyticsDomain: "staging.gumroad-analytics.com",
		ValidRequestHosts:         []string{"staging.gumroad.com", "app.staging.gumroad.com"},
		ValidAPIRequestHosts:      []string{"api.staging.gumroad.com"},
		PublicStorageBucket:       "gumroad-dev-public-storage",
		PublicStorageHost:         "https://staging-public-files.gumroad.com",
		S3ProxyHost:               "https://staging-static-2.gumroad.com",
		AssetDomain:               "staging-assets.gumroad.com",
		PageTitle:                 "Staging Gumroad",
		requiresRevision:          true,
	},
	"development": {
		Protocol:             "http",
		ValidRequestHosts:    []string{"app.localhost", "localhost"},
		ValidAPIRequestHosts: []string{"api.localhost"},
		PublicStorageBucket:  "gumroad-dev-public-storage",
		S3ProxyHost:          "https://staging-static-2.gumroad.com",
		PageTitle:            "Local Gumroad",
	},
}

// LoadEnvironment mirrors config/domain.rb, including the CUSTOM_DOMAIN overrides that
// preview apps set.
func LoadEnvironment(getenv func(string) string) (*Environment, error) {
	name := getenv("RAILS_ENV")
	if name == "" {
		name = "development"
	}
	defaults, ok := environments[name]
	if !ok {
		return nil, fmt.Errorf("unsupported RAILS_ENV %q", name)
	}
	env := defaults
	env.Name = name
	env.ValidRequestHosts = slices.Clone(defaults.ValidRequestHosts)
	env.ValidAPIRequestHosts = slices.Clone(defaults.ValidAPIRequestHosts)
	env.Revision = getenv("REVISION")
	if env.Revision == "" {
		if env.requiresRevision {
			return nil, fmt.Errorf("REVISION is not set")
		}
		env.Revision = getenvDefault(getenv, "REVISION_DEFAULT", "no-revision")
	}
	if name == "production" {
		env.GRNum = getenvDefault(getenv, "ENV_IDENTIFIER_PROD", "PROD")
	} else {
		env.GRNum = getenvDefault(getenv, "ENV_IDENTIFIER_DEV", "DEV")
	}

	if name == "development" {
		port := getenvDefault(getenv, "DEV_LANE_PORT", "3000")
		env.AssetDomain = "app.localhost:" + port
		env.Domain, env.RootDomain = "localhost:"+port, "localhost:"+port
		env.ShortDomain, env.DiscoverDomain = "s.localhost:"+port, "localhost:"+port
		env.APIDomain, env.ThirdPartyAnalyticsDomain = "api.localhost:"+port, "analytics.localhost:"+port
		env.ValidRequestHosts = append(env.ValidRequestHosts, "app.localhost:"+port, "localhost:"+port)
		env.ValidAPIRequestHosts = append(env.ValidAPIRequestHosts, "api.localhost:"+port)
		env.PublicStorageHost = getenvDefault(getenv, "AWS_S3_ENDPOINT", "https://s3.amazonaws.com")
	}
	env.AssetDomain = getenvDefault(getenv, "ASSET_DOMAIN", env.AssetDomain)
	if protocol := strings.TrimSpace(getenv("CUSTOM_PROTOCOL")); protocol != "" {
		env.Protocol = protocol
	}
	if short := getenv("CUSTOM_SHORT_DOMAIN"); short != "" {
		env.ShortDomain = short
	}
	if domain := getenv("CUSTOM_DOMAIN"); domain != "" {
		env.Domain, env.RootDomain, env.DiscoverDomain = domain, domain, domain
		env.ValidRequestHosts = append(env.ValidRequestHosts, domain)
		env.ValidAPIRequestHosts = append(env.ValidAPIRequestHosts, "api."+domain)
		if getenv("BRANCH_DEPLOYMENT") != "" {
			env.ValidAPIRequestHosts = append(env.ValidAPIRequestHosts, domain)
		}
	}
	return &env, nil
}

// AssetHost is config.asset_host.
func (e *Environment) AssetHost() string { return e.Protocol + "://" + e.AssetDomain }

// IsGumroadHost is GumroadDomainConstraint.matches?.
func (e *Environment) IsGumroadHost(host string) bool {
	return slices.Contains(e.ValidRequestHosts, host)
}

func getenvDefault(getenv func(string) string, name, fallback string) string {
	if value := getenv(name); value != "" {
		return value
	}
	return fallback
}
