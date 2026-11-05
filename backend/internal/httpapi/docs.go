package httpapi

import (
	_ "embed"
	"net/http"

	"github.com/gin-gonic/gin"
)

// openAPISpec is the hand-maintained OpenAPI 3.0.3 description of the public
// API, served verbatim at /openapi.json. Embedding it means the binary is the
// single source of truth — there is no file to ship alongside, and the spec
// cannot drift away from the build it was committed with.
//
//go:embed openapi.json
var openAPISpec []byte

// redocPage is the standalone API reference. It pulls Redoc from a CDN and
// points it at /openapi.json, so the docs are always rendered from the same
// spec this binary serves. Self-contained apart from the script tag, so it
// works behind a login-less /docs route on a private network.
const redocPage = `<!DOCTYPE html>
<html>
  <head>
    <title>SOLVANTA API</title>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    <style>body { margin: 0; padding: 0; }</style>
  </head>
  <body>
    <redoc spec-url="/openapi.json"></redoc>
    <script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
  </body>
</html>`

// registerDocs wires the public API-reference routes. Both are unauthenticated:
// the spec describes the contract rather than exposing data, and /docs is a
// static viewer over it.
func (s *Server) registerDocs(r *gin.Engine) {
	r.GET("/openapi.json", func(c *gin.Context) {
		c.Data(http.StatusOK, "application/json; charset=utf-8", openAPISpec)
	})
	r.GET("/docs", func(c *gin.Context) {
		c.Data(http.StatusOK, "text/html; charset=utf-8", []byte(redocPage))
	})
}
