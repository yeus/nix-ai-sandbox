package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"strconv"
	"strings"
	"time"
)

type gatewayServer struct {
	cfg       gatewayConfig
	registry  *registryCache
	transport *http.Transport
}

func newGatewayServer(cfg gatewayConfig) *gatewayServer {
	return &gatewayServer{
		cfg:      cfg,
		registry: &registryCache{path: cfg.Registry},
		transport: &http.Transport{
			DialContext:     (&net.Dialer{Timeout: 2 * time.Second}).DialContext,
			MaxIdleConns:    100,
			IdleConnTimeout: 90 * time.Second,
		},
	}
}

type slotRequest struct {
	slot  int
	token string
}

func parseSlotRequest(r *http.Request) (slotRequest, bool) {
	path := strings.TrimRight(r.URL.Path, "/")
	segments := strings.Split(strings.TrimPrefix(path, "/"), "/")
	if len(segments) != 4 && len(segments) != 3 {
		return slotRequest{}, false
	}
	if segments[0] != "slot" {
		return slotRequest{}, false
	}
	slot, err := strconv.Atoi(segments[1])
	if err != nil || slot < 1 {
		return slotRequest{}, false
	}
	if len(segments) == 4 {
		if segments[3] != "mcp" {
			return slotRequest{}, false
		}
		return slotRequest{slot: slot, token: segments[2]}, true
	}
	if segments[2] != "mcp" {
		return slotRequest{}, false
	}
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return slotRequest{}, false
	}
	return slotRequest{slot: slot, token: strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))}, true
}

func validCapabilityToken(token string) bool {
	if len(token) != 64 {
		return false
	}
	for _, char := range token {
		if (char < '0' || char > '9') && (char < 'a' || char > 'f') {
			return false
		}
	}
	return true
}

func writeJSONError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": code})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(body []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(body)
}

func (s *statusRecorder) Flush() {
	if flusher, ok := s.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (s *statusRecorder) Unwrap() http.ResponseWriter {
	return s.ResponseWriter
}

func (g *gatewayServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	if r.URL.Path == "/healthz" {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte("{\"status\":\"ok\"}\n"))
		return
	}

	request, ok := parseSlotRequest(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "not_found")
		log.Printf("%s /unknown status=404", r.Method)
		return
	}
	label := "/slot/" + strconv.Itoa(request.slot) + "/mcp"
	recorder := &statusRecorder{ResponseWriter: w}
	defer func() {
		log.Printf("%s %s status=%d duration=%s", r.Method, label, recorder.status, time.Since(started).Round(time.Millisecond))
	}()

	if !validCapabilityToken(request.token) {
		writeJSONError(recorder, http.StatusNotFound, "not_found")
		return
	}
	expected, err := g.cfg.slotCapabilityToken(request.slot)
	if err != nil ||
		subtle.ConstantTimeCompare([]byte(expected), []byte(request.token)) != 1 {
		writeJSONError(recorder, http.StatusNotFound, "not_found")
		return
	}

	registry, err := g.registry.load()
	if err != nil {
		log.Printf("slot=%d registry error: %v", request.slot, err)
		writeJSONError(recorder, http.StatusServiceUnavailable, "gateway_unavailable")
		return
	}
	assignment, err := slotUpstreamFor(registry, request.slot)
	if err != nil {
		switch {
		case errors.Is(err, errSlotFree):
			writeJSONError(recorder, http.StatusServiceUnavailable, "slot_free")
		case errors.Is(err, errSlotOutOfRange):
			writeJSONError(recorder, http.StatusNotFound, "not_found")
		default:
			writeJSONError(recorder, http.StatusServiceUnavailable, "slot_unavailable")
		}
		return
	}
	upstream, err := g.cfg.resolveUpstream(assignment)
	if err != nil {
		writeJSONError(recorder, http.StatusServiceUnavailable, "slot_unavailable")
		return
	}
	g.proxySlot(recorder, r, request.slot, upstream)
}

func (g *gatewayServer) proxySlot(w http.ResponseWriter, r *http.Request, slot int, upstream slotUpstream) {
	proxy := &httputil.ReverseProxy{
		Transport:     g.transport,
		FlushInterval: -1,
		Rewrite: func(request *httputil.ProxyRequest) {
			request.Out.URL.Scheme = "http"
			request.Out.URL.Host = upstream.host
			request.Out.URL.Path = "/mcp"
			request.Out.URL.RawPath = ""
			request.Out.Host = upstream.host
			request.Out.Header.Set("Authorization", "Bearer "+upstream.token)
			request.SetXForwarded()
		},
		ErrorHandler: func(rw http.ResponseWriter, req *http.Request, err error) {
			log.Printf("slot=%d upstream error: %v", slot, err)
			writeJSONError(rw, http.StatusServiceUnavailable, "slot_unavailable")
		},
	}
	proxy.ServeHTTP(w, r)
}
