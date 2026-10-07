package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"html/template"
	"io/fs"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jzbz/map.dcr.pw/crawler"
)

var amgr *crawler.Manager
var domain string

// staticFS is the embedded public/ tree, rooted so that the URL path
// /public/css/x maps to the FS path css/x.
var staticFS fs.FS

const timeFormat = "02 Jan 2006 15:04 MST"

// defaultAssetVersion is the cache-busting token used when an asset cannot be
// hashed (e.g. missing file).
const defaultAssetVersion = "dev"

// assetVersions caches a content hash per static asset path so the asset() URLs
// only change when the file's contents change. Computed lazily and cached for
// the life of the process (the embedded assets cannot change without a restart).
var (
	assetMu       sync.Mutex
	assetVersions = map[string]string{}
)

// assetVersion returns a short content hash of the named file in fsys, or "dev"
// if it cannot be read. Pure and side-effect free for testability.
func assetVersion(fsys fs.FS, name string) string {
	if fsys != nil {
		if b, err := fs.ReadFile(fsys, name); err == nil {
			sum := sha256.Sum256(b)
			return hex.EncodeToString(sum[:])[:10]
		}
	}
	return defaultAssetVersion
}

// assetURL appends a short content-hash query string to a static asset path so
// browsers (and the long-lived CDN/proxy cache) re-fetch it whenever it changes,
// while still caching aggressively between changes. webPath is the public URL
// path, e.g. "/public/css/tailwind.css".
func assetURL(webPath string) string {
	assetMu.Lock()
	defer assetMu.Unlock()

	if v, ok := assetVersions[webPath]; ok {
		return webPath + "?v=" + v
	}

	v := assetVersion(staticFS, strings.TrimPrefix(webPath, "/public/"))
	if v == defaultAssetVersion {
		log.Printf("asset %s: could not hash for cache-busting", webPath)
	}
	assetVersions[webPath] = v
	return webPath + "?v=" + v
}

// percent returns a as a whole-number percentage of b, guarding against a
// zero denominator (an empty crawl) so templates can call it unconditionally.
func percent(a, b int) int {
	if b == 0 {
		return 0
	}
	return 100 * a / b
}

// uaPalette colours the user-agent breakdown. It mirrors the JS palette in
// user_agents.html so the donut segments match their version bars.
var uaPalette = []string{
	"#2ED6A1", "#36C5E0", "#5BA8FF", "#9B8CFF",
	"#F5A623", "#FF6B8A", "#7d869c", "#1f9e78",
}

// uaColor returns the accent colour for the i-th user-agent row, cycling the
// palette. The result is template.CSS so it can be dropped into an inline
// custom-property declaration without the HTML sanitiser rejecting it.
func uaColor(i int) template.CSS {
	return template.CSS(uaPalette[((i%len(uaPalette))+len(uaPalette))%len(uaPalette)])
}

// securityHeaders sets conservative response headers on every request.
func securityHeaders() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("X-Content-Type-Options", "nosniff")
		c.Header("Referrer-Policy", "strict-origin-when-cross-origin")
		c.Next()
	}
}

// NewRouter builds the HTTP router, serving templates and static assets from the
// provided (embedded) filesystems. static must be rooted at the public/ tree.
func NewRouter(templates, static fs.FS) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	staticFS = static

	router := gin.New()

	// Recovery middleware handles any go panics generated while processing web
	// requests. Ensures a 500 response is sent to the client rather than
	// sending no response at all.
	router.Use(gin.Recovery())
	router.Use(securityHeaders())

	funcMap := template.FuncMap{
		"incr":    func(i int) int { return i + 1 },
		"date":    func(t time.Time) string { return t.In(time.UTC).Format(timeFormat) },
		"asset":   assetURL,
		"pct":     percent,
		"uacolor": uaColor,
	}
	tmpl := template.Must(template.New("").Funcs(funcMap).ParseFS(templates, "templates/*"))
	router.SetHTMLTemplate(tmpl)

	router.StaticFS("/public", http.FS(static))

	// Page routes.
	router.GET("/", homepage)
	router.GET("/all_nodes", list)
	router.GET("/user_agents", userAgents)
	router.GET("/node", node)

	// Page API routes.
	router.GET("/world_nodes", worldNodes)
	router.GET("/nodes", paginatedNodes)

	// Data API routes.
	router.GET("/api/user_agents", api)

	return router
}

func Start(ctx context.Context, listen string, cookieDomain string, mgr *crawler.Manager, requestShutdownChan chan struct{}, shutdownWg *sync.WaitGroup, templates, static fs.FS) error {
	amgr = mgr
	domain = cookieDomain

	// Create TCP listener.
	var listenConfig net.ListenConfig
	listener, err := listenConfig.Listen(ctx, "tcp", listen)
	if err != nil {
		return err
	}
	log.Printf("Listening on %s", listen)

	srv := http.Server{
		Handler:           NewRouter(templates, static),
		ReadTimeout:       5 * time.Second,  // slow requests should not hold connections opened
		ReadHeaderTimeout: 5 * time.Second,  // bound slow header sends (slowloris)
		WriteTimeout:      60 * time.Second, // hung responses must die
		MaxHeaderBytes:    1 << 20,          // 1 MiB cap on request headers
	}

	// Add the graceful shutdown to the waitgroup.
	shutdownWg.Add(1)
	go func() {
		// Wait until shutdown is signaled before shutting down.
		<-ctx.Done()

		// Give the webserver 10 seconds to finish what it is doing.
		timeoutCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(timeoutCtx); err != nil {
			log.Printf("Failed to stop webserver cleanly: %v", err)
		} else {
			log.Printf("Webserver stopped")
		}
		shutdownWg.Done()
	}()

	// Start webserver.
	go func() {
		// If the server dies for any reason other than ErrServerClosed (from
		// graceful server.Shutdown), log the error and request shutdown.
		if err := srv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("Unexpected webserver error: %v", err)
			requestShutdownChan <- struct{}{}
		}
	}()

	return nil
}
