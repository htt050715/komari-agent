package update

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

type proxyTestTransport func(*http.Request) (*http.Response, error)

func (f proxyTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestGitHubProxyFallback(t *testing.T) {
	t.Setenv("KOMARI_GITHUB_PROXY", defaultGitHubProxy)
	for _, failure := range []string{"none", "network", "status", "json"} {
		t.Run(failure, func(t *testing.T) {
			var hosts []string
			client := &http.Client{Transport: proxyTestTransport(func(r *http.Request) (*http.Response, error) {
				hosts = append(hosts, r.URL.Host)
				status, body := 200, `[]`
				if r.URL.Host != "api.github.com" {
					if !strings.HasPrefix(r.URL.Path, "/https://api.github.com/repos/") {
						t.Fatalf("wrong proxy URL: %s", r.URL)
					}
					switch failure {
					case "network":
						return nil, fmt.Errorf("offline")
					case "status":
						status = 404
					case "json":
						body = "<html>bad gateway</html>"
					}
				}
				return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
			})}
			req, _ := http.NewRequest("GET", "https://api.github.com/repos/htt050715/komari-agent/releases?page=1", nil)
			err := fetchGitHub(client, req, func(r *http.Response) error {
				var releases []githubRelease
				return json.NewDecoder(r.Body).Decode(&releases)
			})
			if err != nil {
				t.Fatal(err)
			}
			want := []string{"ghproxy.05160715.xyz"}
			if failure != "none" {
				want = append(want, "api.github.com")
			}
			if !reflect.DeepEqual(hosts, want) {
				t.Fatalf("hosts = %v, want %v", hosts, want)
			}
		})
	}
}

func TestGitHubProxyDoesNotForwardCredentials(t *testing.T) {
	t.Setenv("KOMARI_GITHUB_PROXY", defaultGitHubProxy)
	for _, header := range []string{"Authorization", "Cookie"} {
		req, _ := http.NewRequest("GET", "https://api.github.com/repos/owner/repo/releases", nil)
		req.Header.Set(header, "test-secret")
		urls := githubRequestURLs(req)
		if len(urls) != 1 || urls[0].Host != "api.github.com" {
			t.Fatalf("credential request proxied: %v", urls)
		}
	}
	t.Setenv("GITHUB_TOKEN", "test-secret")
	req, err := assetRequest("owner", "repo", githubReleaseAsset{ID: 42})
	if err != nil {
		t.Fatal(err)
	}
	if len(githubRequestURLs(req)) != 1 || req.Header.Get("Authorization") != "Bearer test-secret" {
		t.Fatal("authenticated asset must stay direct")
	}
	t.Setenv("KOMARI_GITHUB_PROXY", "")
	req.Header.Del("Authorization")
	if len(githubRequestURLs(req)) != 1 {
		t.Fatal("empty proxy override must disable proxy")
	}
}

func TestDownloadAssetRetriesCorruptProxy(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "")
	t.Setenv("KOMARI_GITHUB_PROXY", defaultGitHubProxy)
	good := "good-binary"
	sum := sha256.Sum256([]byte(good))
	asset := githubReleaseAsset{Size: len(good), Digest: fmt.Sprintf("sha256:%x", sum), BrowserDownloadURL: "https://github.com/htt050715/komari-agent/releases/download/1.5.13/agent.exe"}
	var hosts []string
	client := &http.Client{Transport: proxyTestTransport(func(r *http.Request) (*http.Response, error) {
		hosts = append(hosts, r.URL.Host)
		body := good
		if r.URL.Host != "github.com" {
			body = "evil-binary"
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header)}, nil
	})}
	data, err := downloadAsset(client, "owner", "repo", asset)
	if err != nil || string(data) != good {
		t.Fatalf("download = %q, %v", data, err)
	}
	if !reflect.DeepEqual(hosts, []string{"ghproxy.05160715.xyz", "github.com"}) {
		t.Fatal(hosts)
	}
}
