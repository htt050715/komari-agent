package update

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
)

const defaultGitHubProxy = "https://ghproxy.05160715.xyz"

// Authenticated requests never pass through the public proxy. An explicitly
// empty KOMARI_GITHUB_PROXY disables it; other HTTPS prefixes override it.
func githubRequestURLs(req *http.Request) []*url.URL {
	direct := []*url.URL{req.URL}
	if req.URL.Scheme != "https" || req.URL.User != nil ||
		(req.URL.Host != "github.com" && req.URL.Host != "api.github.com" && req.URL.Host != "raw.githubusercontent.com") ||
		req.Header.Get("Authorization") != "" || req.Header.Get("Cookie") != "" {
		return direct
	}
	prefix, set := os.LookupEnv("KOMARI_GITHUB_PROXY")
	if !set {
		prefix = defaultGitHubProxy
	}
	base, err := url.Parse(prefix)
	if err != nil || base.Scheme != "https" || base.Host == "" || base.User != nil || base.RawQuery != "" || base.Fragment != "" {
		return direct
	}
	proxied, err := url.Parse(strings.TrimRight(prefix, "/") + "/" + req.URL.String())
	if err != nil {
		return direct
	}
	return []*url.URL{proxied, req.URL}
}

// Retry directly on transport, HTTP, JSON, size or checksum failures. Consume
// and close each response before retrying so a bad mirror cannot be installed.
func fetchGitHub(client *http.Client, req *http.Request, consume func(*http.Response) error) error {
	var lastErr error
	for _, endpoint := range githubRequestURLs(req) {
		attempt := req.Clone(req.Context())
		attempt.URL = endpoint
		resp, err := client.Do(attempt)
		if err != nil {
			lastErr = err
			continue
		}
		if resp.StatusCode != http.StatusOK {
			err = fmt.Errorf("GitHub request returned status %d", resp.StatusCode)
		} else {
			err = consume(resp)
		}
		_ = resp.Body.Close()
		if err == nil {
			return nil
		}
		lastErr = err
	}
	return lastErr
}
