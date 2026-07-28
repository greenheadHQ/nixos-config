package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const usage = `usage:
  claudex-gate serve [options]
  claudex-gate control inspect --socket PATH
  claudex-gate control drain-stop --socket PATH --instance NONCE --generation ID --timeout-seconds N [--force]
`

const backendCertificateLifetime = 10 * 365 * 24 * time.Hour

var (
	errBackendExitedClean = errors.New("backend exited cleanly")
	errStartupInterrupted = errors.New("gate startup interrupted by signal")
	errRuntimeLockOwned   = errors.New("another claudex gate owns the runtime lock")
)

type serveOptions struct {
	mode             string
	stateDir         string
	authDir          string
	workDir          string
	configFile       string
	publicKeyFile    string
	backendBin       string
	generation       string
	publicAddress    string
	backendAddress   string
	controlSocket    string
	logFile          string
	home             string
	drainSeconds     int
	childStopSeconds int
	startupLockFD    int
}

type snapshot struct {
	Schema            int    `json:"schema"`
	Instance          string `json:"instance"`
	Generation        string `json:"generation"`
	Mode              string `json:"mode"`
	State             string `json:"state"`
	Accepting         bool   `json:"accepting"`
	Active            int    `json:"active"`
	GatePID           int    `json:"gate_pid"`
	GateExecutable    string `json:"gate_executable"`
	BackendPID        int    `json:"backend_pid"`
	BackendExecutable string `json:"backend_executable"`
}

type controlRequest struct {
	Command        string `json:"command"`
	Instance       string `json:"instance,omitempty"`
	Generation     string `json:"generation,omitempty"`
	TimeoutSeconds int    `json:"timeout_seconds,omitempty"`
	Force          bool   `json:"force,omitempty"`
}

type controlResponse struct {
	OK       bool      `json:"ok"`
	Code     string    `json:"code,omitempty"`
	Message  string    `json:"message,omitempty"`
	Snapshot *snapshot `json:"snapshot,omitempty"`
}

type credentialEntry struct {
	name     string
	provider string
	raw      []byte
}

type gate struct {
	options serveOptions

	mu            sync.Mutex
	state         string
	active        int
	nextRequestID uint64
	activeCancels map[uint64]context.CancelFunc
	drainZero     chan struct{}
	terminalStop  bool

	instance           string
	gateExecutable     string
	publicKey          string
	backendKey         string
	backendTLS         *tls.Config
	childConfig        string
	instanceDir        string
	credentialSnapshot string
	child              *exec.Cmd
	childDone          chan struct{}
	childExited        bool
	unexpectedChild    bool
	startupErr         error
	suppressRestart    bool
	publicListener     net.Listener
	publicServer       *http.Server
	control            net.Listener
	proxy              *httputil.ReverseProxy
	lockFile           *os.File
	logFile            *os.File
	logger             *log.Logger

	stopOnce   sync.Once
	stopped    chan struct{}
	stopExit   int
	stopError  error
	finishOnce sync.Once
	done       chan struct{}
	exitCode   int
}

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	if len(args) == 1 && (args[0] == "--help" || args[0] == "help") {
		fmt.Print(usage)
		return 0
	}
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
	switch args[0] {
	case "serve":
		return runServe(args[1:])
	case "control":
		return runControl(args[1:])
	default:
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
}

func runServe(args []string) int {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var options serveOptions
	flags.StringVar(&options.mode, "mode", "", "managed or foreground")
	flags.StringVar(&options.stateDir, "state-dir", "", "private state directory")
	flags.StringVar(&options.authDir, "auth-dir", "", "credential directory")
	flags.StringVar(&options.workDir, "work-dir", "", "fixed backend working directory")
	flags.StringVar(&options.configFile, "config", "", "canonical config")
	flags.StringVar(&options.publicKeyFile, "public-key-file", "", "public API key file")
	flags.StringVar(&options.backendBin, "backend-bin", "", "pinned CLIProxyAPI executable")
	flags.StringVar(&options.generation, "generation", "", "declared runtime generation")
	flags.StringVar(&options.publicAddress, "public-address", "127.0.0.1:8317", "public address")
	flags.StringVar(&options.backendAddress, "backend-address", "127.0.0.1:8318", "private backend address")
	flags.StringVar(&options.controlSocket, "control-socket", "", "private control socket")
	flags.StringVar(&options.logFile, "log-file", "", "private combined log")
	flags.StringVar(&options.home, "home", "", "declared user home")
	flags.IntVar(&options.drainSeconds, "drain-seconds", 30, "signal drain budget")
	flags.IntVar(&options.childStopSeconds, "child-stop-seconds", 10, "child stop budget")
	flags.IntVar(&options.startupLockFD, "startup-lock-fd", -1, "inherited lifecycle lock descriptor")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
	if err := validateServeOptions(&options); err != nil {
		fmt.Fprintf(os.Stderr, "claudex-gate: %v\n", err)
		return 2
	}
	runtime, err := newGate(options)
	if err != nil {
		fmt.Fprintf(os.Stderr, "claudex-gate: %v\n", err)
		return 1
	}
	return runtime.serve()
}

func validateServeOptions(options *serveOptions) error {
	if options.mode != "managed" && options.mode != "foreground" {
		return errors.New("--mode must be managed or foreground")
	}
	required := map[string]string{
		"--state-dir":       options.stateDir,
		"--auth-dir":        options.authDir,
		"--work-dir":        options.workDir,
		"--config":          options.configFile,
		"--public-key-file": options.publicKeyFile,
		"--backend-bin":     options.backendBin,
		"--generation":      options.generation,
		"--control-socket":  options.controlSocket,
		"--log-file":        options.logFile,
	}
	for name, value := range required {
		if value == "" {
			return fmt.Errorf("%s is required", name)
		}
	}
	if options.drainSeconds < 0 || options.childStopSeconds < 0 {
		return errors.New("stop budgets must be nonnegative")
	}
	if options.startupLockFD != -1 && options.startupLockFD < 3 {
		return errors.New("--startup-lock-fd requires a descriptor >= 3")
	}
	for _, address := range []string{options.publicAddress, options.backendAddress} {
		host, _, err := net.SplitHostPort(address)
		if err != nil || host != "127.0.0.1" {
			return fmt.Errorf("address must be an explicit 127.0.0.1 host:port: %s", address)
		}
	}
	if options.home == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		options.home = home
	}
	return nil
}

func newGate(options serveOptions) (*gate, error) {
	instance, err := randomHex(16)
	if err != nil {
		return nil, err
	}
	gateExecutable, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("resolve gate executable: %w", err)
	}
	runtime := &gate{
		options:        options,
		state:          "starting",
		instance:       instance,
		gateExecutable: gateExecutable,
		activeCancels:  make(map[uint64]context.CancelFunc),
		childDone:      make(chan struct{}),
		stopped:        make(chan struct{}),
		done:           make(chan struct{}),
	}
	return runtime, nil
}

func (g *gate) serve() int {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	if err := g.prepare(signals); err != nil {
		g.logf("claudex-gate: %v", err)
		g.cleanup()
		if errors.Is(err, errBackendExitedClean) || errors.Is(err, errStartupInterrupted) {
			return 0
		}
		if g.options.mode == "managed" && g.managedRestartSuppressed() {
			return 0
		}
		return 1
	}
	go func() {
		select {
		case <-signals:
			g.stopFromSignal()
		case <-g.done:
		}
	}()
	<-g.done
	g.cleanup()
	return g.exitCode
}

func (g *gate) prepare(signals <-chan os.Signal) error {
	for _, dir := range []string{g.options.stateDir, g.options.authDir, g.options.workDir} {
		if err := assertPrivateDir(dir); err != nil {
			return err
		}
	}
	keyBytes, err := os.ReadFile(g.options.publicKeyFile)
	if err != nil {
		return fmt.Errorf("read public key: %w", err)
	}
	g.publicKey = strings.TrimSpace(string(keyBytes))
	if len(g.publicKey) != 64 {
		return errors.New("public API key must be 64 characters")
	}
	if err := assertPrivateRegular(g.options.publicKeyFile); err != nil {
		return err
	}
	if err := validateCredentialSet(g.options.authDir); err != nil {
		g.suppressManagedRestart()
		return err
	}
	if err := g.acquireRuntimeLock(); err != nil {
		if errors.Is(err, errRuntimeLockOwned) {
			g.suppressManagedRestart()
		}
		return err
	}
	logFile, err := g.openLog()
	if err != nil {
		return err
	}
	if err := g.prepareBackend(); err != nil {
		return err
	}
	if err := g.bindPublic(); err != nil {
		if errors.Is(err, syscall.EADDRINUSE) {
			g.suppressManagedRestart()
		}
		return err
	}
	if err := g.bindControl(); err != nil {
		return err
	}
	if err := g.releaseStartupLock(); err != nil {
		return err
	}
	if err := g.startChild(logFile); err != nil {
		return err
	}
	if err := g.waitBackendReady(signals); err != nil {
		return g.abortStartup(err)
	}
	g.mu.Lock()
	if g.childExited {
		err := g.startupErr
		g.mu.Unlock()
		if err == nil {
			err = errors.New("backend exited during startup")
		}
		return g.abortStartup(err)
	}
	if g.startupErr != nil {
		err := g.startupErr
		g.mu.Unlock()
		return g.abortStartup(err)
	}
	g.state = "open"
	g.mu.Unlock()
	return nil
}

func (g *gate) abortStartup(startupErr error) error {
	if g.childCommand() != nil {
		select {
		case <-g.childDone:
		default:
			_ = g.signalChild(syscall.SIGTERM)
			timer := time.NewTimer(time.Duration(g.options.childStopSeconds) * time.Second)
			select {
			case <-g.childDone:
				timer.Stop()
			case <-timer.C:
				_ = g.signalChild(syscall.SIGKILL)
				<-g.childDone
			}
		}
	}
	stateLock, lockErr := g.acquireStateLock()
	if lockErr != nil {
		g.suppressManagedRestart()
		return fmt.Errorf("%w; credential recovery lock failed: %v", startupErr, lockErr)
	}
	defer releaseFileLock(stateLock)
	if recoveryErr := g.recoverCredentialSet(); recoveryErr != nil {
		g.suppressManagedRestart()
		return fmt.Errorf("%w; credential recovery failed: %v", startupErr, recoveryErr)
	}
	return startupErr
}

func (g *gate) childCommand() *exec.Cmd {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.child
}

func (g *gate) managedRestartSuppressed() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.suppressRestart
}

func (g *gate) suppressManagedRestart() {
	g.mu.Lock()
	g.suppressRestart = true
	g.mu.Unlock()
}

func (g *gate) acquireRuntimeLock() error {
	path := filepath.Join(g.options.stateDir, "runtime.lock")
	info, err := os.Lstat(path)
	if err == nil && info.Mode()&os.ModeSymlink != 0 {
		return errors.New("refusing symlink runtime lock")
	}
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		file.Close()
		return err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		return errRuntimeLockOwned
	}
	g.lockFile = file
	return nil
}

func (g *gate) releaseStartupLock() error {
	if g.options.startupLockFD < 0 {
		return nil
	}
	fd := g.options.startupLockFD
	if err := syscall.Flock(fd, syscall.LOCK_UN); err != nil {
		return fmt.Errorf("release startup lifecycle lock: %w", err)
	}
	if err := syscall.Close(fd); err != nil {
		return fmt.Errorf("close startup lifecycle lock: %w", err)
	}
	g.options.startupLockFD = -1
	return nil
}

func (g *gate) prepareBackend() error {
	instanceDir := filepath.Join(g.options.stateDir, "instances", g.instance)
	g.instanceDir = instanceDir
	if err := os.MkdirAll(instanceDir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(filepath.Dir(instanceDir), 0o700); err != nil {
		return err
	}
	if err := os.Chmod(instanceDir, 0o700); err != nil {
		return err
	}
	snapshotPath, err := copyCredentialSet(g.options.authDir, instanceDir, "credentials-startup")
	if err != nil {
		return fmt.Errorf("snapshot credentials: %w", err)
	}
	g.credentialSnapshot = snapshotPath
	backendKey, err := randomHex(32)
	if err != nil {
		return err
	}
	g.backendKey = backendKey
	certPath := filepath.Join(instanceDir, "backend-cert.pem")
	keyPath := filepath.Join(instanceDir, "backend-key.pem")
	ca, err := generateBackendCertificate(certPath, keyPath)
	if err != nil {
		return err
	}
	g.backendTLS = &tls.Config{
		MinVersion: tls.VersionTLS12,
		RootCAs:    ca,
		ServerName: "claudex-backend",
	}
	raw, err := os.ReadFile(g.options.configFile)
	if err != nil {
		return err
	}
	var config map[string]any
	if err := json.Unmarshal(raw, &config); err != nil {
		return fmt.Errorf("parse canonical config: %w", err)
	}
	host, portString, err := net.SplitHostPort(g.options.backendAddress)
	if err != nil {
		return err
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		return err
	}
	config["host"] = host
	config["port"] = port
	config["auth-dir"] = g.options.authDir
	config["api-keys"] = []string{g.backendKey}
	config["tls"] = map[string]any{
		"enable": true,
		"cert":   certPath,
		"key":    keyPath,
	}
	childConfig := filepath.Join(instanceDir, "config.json")
	encoded, err := json.Marshal(config)
	if err != nil {
		return err
	}
	if err := os.WriteFile(childConfig, encoded, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(childConfig, 0o600); err != nil {
		return err
	}
	g.childConfig = childConfig
	return nil
}

func (g *gate) bindPublic() error {
	listener, err := net.Listen("tcp", g.options.publicAddress)
	if err != nil {
		return fmt.Errorf("bind public listener: %w", err)
	}
	g.publicListener = listener
	backendURL := &url.URL{Scheme: "https", Host: g.options.backendAddress}
	proxy := httputil.NewSingleHostReverseProxy(backendURL)
	proxy.Transport = &http.Transport{
		Proxy:                 nil,
		TLSClientConfig:       g.backendTLS.Clone(),
		ForceAttemptHTTP2:     true,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 0,
	}
	proxy.FlushInterval = -1
	originalDirector := proxy.Director
	proxy.Director = func(request *http.Request) {
		originalDirector(request)
		stripPublicCredentials(request)
		request.Header.Set("Authorization", "Bearer "+g.backendKey)
	}
	proxy.ErrorHandler = func(writer http.ResponseWriter, _ *http.Request, err error) {
		g.logf("claudex-gate backend error: %v", err)
		http.Error(writer, "backend unavailable", http.StatusBadGateway)
	}
	g.proxy = proxy
	g.publicServer = &http.Server{
		Handler:           http.HandlerFunc(g.handlePublic),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		err := g.publicServer.Serve(listener)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			g.failUnexpected(fmt.Errorf("public listener: %w", err))
		}
	}()
	return nil
}

func (g *gate) bindControl() error {
	if err := os.MkdirAll(filepath.Dir(g.options.controlSocket), 0o700); err != nil {
		return err
	}
	if info, err := os.Lstat(g.options.controlSocket); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || info.Mode()&os.ModeSocket == 0 {
			return errors.New("refusing unsafe control socket path")
		}
		if err := os.Remove(g.options.controlSocket); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	listener, err := net.Listen("unix", g.options.controlSocket)
	if err != nil {
		return err
	}
	if err := os.Chmod(g.options.controlSocket, 0o600); err != nil {
		listener.Close()
		return err
	}
	g.control = listener
	go g.serveControl()
	return nil
}

func (g *gate) startChild(logFile *os.File) error {
	command := exec.Command(g.options.backendBin, "--config", g.childConfig, "--local-model")
	command.Dir = g.options.workDir
	command.Env = []string{
		"HOME=" + g.options.home,
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
		"TMPDIR=/tmp",
		"NO_PROXY=127.0.0.1,localhost",
		"no_proxy=127.0.0.1,localhost",
	}
	command.Stdout = logFile
	command.Stderr = logFile
	if g.options.mode == "foreground" {
		command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	}
	if err := command.Start(); err != nil {
		return err
	}
	g.mu.Lock()
	g.child = command
	g.mu.Unlock()
	go func() {
		err := command.Wait()
		g.mu.Lock()
		g.childExited = true
		state := g.state
		if state != "stopping" && state != "stopped" {
			g.unexpectedChild = true
		}
		if state == "starting" {
			if err == nil {
				g.startupErr = errBackendExitedClean
			} else {
				g.startupErr = fmt.Errorf("backend exited during startup: %w", err)
			}
		}
		g.mu.Unlock()
		close(g.childDone)
		if state != "starting" && state != "stopping" && state != "stopped" {
			if err == nil {
				g.failUnexpected(errors.New("backend exited unexpectedly with status 0"))
			} else {
				g.failUnexpected(fmt.Errorf("backend exited: %w", err))
			}
		}
	}()
	return nil
}

func (g *gate) waitBackendReady(signals <-chan os.Signal) error {
	client := &http.Client{
		Transport: &http.Transport{
			Proxy:           nil,
			TLSClientConfig: g.backendTLS.Clone(),
		},
		Timeout: 2 * time.Second,
	}
	endpoint := "https://" + g.options.backendAddress + "/v1/models"
	for attempt := 0; attempt < 40; attempt++ {
		select {
		case <-signals:
			return errStartupInterrupted
		default:
		}
		g.mu.Lock()
		startupErr := g.startupErr
		g.mu.Unlock()
		if startupErr != nil {
			return startupErr
		}
		select {
		case <-g.childDone:
			g.mu.Lock()
			startupErr = g.startupErr
			g.mu.Unlock()
			if startupErr != nil {
				return startupErr
			}
			return errors.New("backend exited before readiness")
		default:
		}
		request, _ := http.NewRequest(http.MethodGet, endpoint, nil)
		request.Header.Set("Authorization", "Bearer "+g.backendKey)
		response, err := client.Do(request)
		if err == nil {
			var payload struct {
				Data []json.RawMessage `json:"data"`
			}
			decodeErr := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&payload)
			response.Body.Close()
			if response.StatusCode == http.StatusOK && decodeErr == nil && payload.Data != nil {
				return nil
			}
		}
		timer := time.NewTimer(100 * time.Millisecond)
		select {
		case <-signals:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return errStartupInterrupted
		case <-timer.C:
		}
	}
	return errors.New("backend did not become ready")
}

func (g *gate) handlePublic(writer http.ResponseWriter, request *http.Request) {
	if !authenticatePublicRequest(request, g.publicKey) {
		http.Error(writer, "unauthorized", http.StatusUnauthorized)
		return
	}
	g.mu.Lock()
	if g.state != "open" {
		g.mu.Unlock()
		writer.Header().Set("Retry-After", "1")
		http.Error(writer, "proxy is not accepting new requests", http.StatusServiceUnavailable)
		return
	}
	g.nextRequestID++
	requestID := g.nextRequestID
	contextWithCancel, cancel := context.WithCancel(request.Context())
	g.activeCancels[requestID] = cancel
	g.active++
	g.mu.Unlock()

	defer func() {
		cancel()
		g.mu.Lock()
		delete(g.activeCancels, requestID)
		g.active--
		if g.active == 0 && g.drainZero != nil {
			close(g.drainZero)
			g.drainZero = nil
		}
		g.mu.Unlock()
	}()
	g.proxy.ServeHTTP(writer, request.WithContext(contextWithCancel))
}

func authenticatePublicRequest(request *http.Request, expected string) bool {
	candidates := []string{
		request.Header.Get("Authorization"),
		request.Header.Get("X-Goog-Api-Key"),
		request.Header.Get("X-Api-Key"),
		request.URL.Query().Get("key"),
		request.URL.Query().Get("auth_token"),
	}
	for _, candidate := range candidates {
		candidate = strings.TrimSpace(candidate)
		if len(candidate) >= 7 && strings.EqualFold(candidate[:7], "bearer ") {
			candidate = strings.TrimSpace(candidate[7:])
		}
		if len(candidate) == len(expected) &&
			subtle.ConstantTimeCompare([]byte(candidate), []byte(expected)) == 1 {
			return true
		}
	}
	return false
}

func stripPublicCredentials(request *http.Request) {
	request.Header.Del("Authorization")
	request.Header.Del("X-Goog-Api-Key")
	request.Header.Del("X-Api-Key")
	query := request.URL.Query()
	query.Del("key")
	query.Del("auth_token")
	request.URL.RawQuery = query.Encode()
}

func (g *gate) serveControl() {
	for {
		connection, err := g.control.Accept()
		if err != nil {
			select {
			case <-g.stopped:
				return
			default:
				g.failUnexpected(fmt.Errorf("control listener: %w", err))
				return
			}
		}
		go g.handleControl(connection)
	}
}

func (g *gate) handleControl(connection net.Conn) {
	defer connection.Close()
	_ = connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	var request controlRequest
	if err := json.NewDecoder(io.LimitReader(connection, 64<<10)).Decode(&request); err != nil {
		_ = json.NewEncoder(connection).Encode(controlResponse{OK: false, Code: "INVALID", Message: "invalid control request"})
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	switch request.Command {
	case "inspect":
		current := g.snapshot()
		_ = json.NewEncoder(connection).Encode(controlResponse{OK: true, Snapshot: &current})
	case "drain-stop":
		if request.TimeoutSeconds < 0 {
			_ = json.NewEncoder(connection).Encode(controlResponse{OK: false, Code: "INVALID", Message: "timeout must be nonnegative"})
			return
		}
		disconnected := make(chan struct{})
		go func() {
			var buffer [1]byte
			_, _ = connection.Read(buffer[:])
			close(disconnected)
		}()
		response, committed := g.drainAndStop(request, disconnected)
		if !committed {
			_ = json.NewEncoder(connection).Encode(response)
			return
		}
		exitCode, stopError := g.stopProcess(request.Force)
		if stopError != nil {
			_ = json.NewEncoder(connection).Encode(controlResponse{
				OK:      false,
				Code:    "RECOVERY_FAILED",
				Message: "credential recovery failed; operator action is required",
			})
			g.finish(exitCode)
			return
		}
		_ = json.NewEncoder(connection).Encode(controlResponse{OK: exitCode == 0, Code: "STOPPED"})
		g.finish(exitCode)
	default:
		_ = json.NewEncoder(connection).Encode(controlResponse{OK: false, Code: "INVALID", Message: "unknown control command"})
	}
}

func (g *gate) snapshot() snapshot {
	g.mu.Lock()
	defer g.mu.Unlock()
	childPID := 0
	if g.child != nil && g.child.Process != nil {
		childPID = g.child.Process.Pid
	}
	return snapshot{
		Schema:            1,
		Instance:          g.instance,
		Generation:        g.options.generation,
		Mode:              g.options.mode,
		State:             g.state,
		Accepting:         g.state == "open",
		Active:            g.active,
		GatePID:           os.Getpid(),
		GateExecutable:    g.gateExecutable,
		BackendPID:        childPID,
		BackendExecutable: g.options.backendBin,
	}
}

func (g *gate) drainAndStop(request controlRequest, disconnected <-chan struct{}) (controlResponse, bool) {
	g.mu.Lock()
	if g.options.mode != "managed" {
		g.mu.Unlock()
		return controlResponse{OK: false, Code: "FOREGROUND", Message: "stop the foreground proxy with Ctrl-C"}, false
	}
	if request.Instance != g.instance || request.Generation != g.options.generation {
		g.mu.Unlock()
		return controlResponse{OK: false, Code: "STALE", Message: "instance or generation does not match"}, false
	}
	if g.state != "open" {
		code := "NOT_OPEN"
		if g.state == "draining" {
			code = "DRAIN_IN_PROGRESS"
		}
		g.mu.Unlock()
		return controlResponse{OK: false, Code: code, Message: "proxy is not open"}, false
	}
	g.state = "draining"
	if request.Force {
		for _, cancel := range g.activeCancels {
			cancel()
		}
		g.state = "stopping"
		g.mu.Unlock()
		return controlResponse{OK: true, Code: "STOPPING"}, true
	}
	if g.active == 0 {
		g.state = "stopping"
		g.mu.Unlock()
		return controlResponse{OK: true, Code: "STOPPING"}, true
	}
	zero := make(chan struct{})
	g.drainZero = zero
	g.mu.Unlock()

	timer := time.NewTimer(time.Duration(request.TimeoutSeconds) * time.Second)
	defer timer.Stop()
	select {
	case <-zero:
		g.mu.Lock()
		if g.state == "draining" {
			g.state = "stopping"
			g.mu.Unlock()
			return controlResponse{OK: true, Code: "STOPPING"}, true
		}
		g.mu.Unlock()
		return controlResponse{OK: false, Code: "UNKNOWN"}, false
	case <-timer.C:
		return g.reopenAfterAbortedDrain(zero, "BUSY_REOPENED")
	case <-disconnected:
		return g.reopenAfterAbortedDrain(zero, "CALLER_DISCONNECTED")
	}
}

func (g *gate) reopenAfterAbortedDrain(zero chan struct{}, code string) (controlResponse, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.state != "draining" {
		return controlResponse{OK: false, Code: "UNKNOWN"}, false
	}
	if g.active == 0 {
		g.state = "stopping"
		g.drainZero = nil
		return controlResponse{OK: true, Code: "STOPPING"}, true
	}
	if g.terminalStop {
		return controlResponse{OK: false, Code: "STOPPING", Message: "terminal shutdown is already in progress"}, false
	}
	if g.drainZero != zero {
		return controlResponse{OK: false, Code: "UNKNOWN"}, false
	}
	g.state = "open"
	g.drainZero = nil
	return controlResponse{OK: false, Code: code, Message: "active requests remain; admission reopened"}, false
}

func (g *gate) stopFromSignal() {
	g.mu.Lock()
	if g.state == "stopping" || g.state == "stopped" {
		g.mu.Unlock()
		return
	}
	g.terminalStop = true
	g.state = "draining"
	if g.active == 0 {
		g.state = "stopping"
		g.mu.Unlock()
		exitCode, _ := g.stopProcess(false)
		g.finish(exitCode)
		return
	}
	zero := g.drainZero
	if zero == nil {
		zero = make(chan struct{})
		g.drainZero = zero
	}
	forceAtDeadline := time.NewTimer(time.Duration(g.options.drainSeconds) * time.Second)
	g.mu.Unlock()
	select {
	case <-zero:
		forceAtDeadline.Stop()
	case <-forceAtDeadline.C:
		g.mu.Lock()
		for _, cancel := range g.activeCancels {
			cancel()
		}
		g.mu.Unlock()
	}
	g.mu.Lock()
	g.state = "stopping"
	g.mu.Unlock()
	exitCode, _ := g.stopProcess(false)
	g.finish(exitCode)
}

func (g *gate) stopProcess(force bool) (int, error) {
	g.stopOnce.Do(func() {
		if g.publicServer != nil {
			if force {
				_ = g.publicServer.Close()
			} else {
				context, cancel := context.WithTimeout(context.Background(), time.Second)
				_ = g.publicServer.Shutdown(context)
				cancel()
			}
		}
		if g.control != nil {
			_ = g.control.Close()
		}
		stateLock, recoveryErr := g.acquireStateLock()
		if recoveryErr == nil {
			defer releaseFileLock(stateLock)
			g.captureLatestCredentialSnapshot()
		}
		if g.childCommand() != nil {
			select {
			case <-g.childDone:
			default:
				_ = g.signalChild(syscall.SIGTERM)
				timer := time.NewTimer(time.Duration(g.options.childStopSeconds) * time.Second)
				select {
				case <-g.childDone:
					timer.Stop()
				case <-timer.C:
					_ = g.signalChild(syscall.SIGKILL)
					<-g.childDone
				}
			}
		}
		if recoveryErr == nil {
			recoveryErr = g.recoverCredentialSet()
		}
		g.mu.Lock()
		if recoveryErr != nil {
			g.logf("claudex-gate: credential recovery failed: %v", recoveryErr)
			// Avoid an on-failure restart loop while the canonical auth set is invalid.
			g.stopExit = 0
			g.stopError = errors.New("credential recovery failed")
		} else if g.unexpectedChild {
			g.stopExit = 1
		}
		g.state = "stopped"
		g.mu.Unlock()
		close(g.stopped)
	})
	<-g.stopped
	return g.stopExit, g.stopError
}

func (g *gate) acquireStateLock() (*os.File, error) {
	path := filepath.Join(g.options.stateDir, "state.lock")
	info, err := os.Lstat(path)
	if err == nil && (!info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0) {
		return nil, errors.New("refusing non-regular or symlink state lock")
	}
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, err
	}
	locked := false
	defer func() {
		if !locked {
			_ = file.Close()
		}
	}()
	fileInfo, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !fileInfo.Mode().IsRegular() || fileInfo.Mode().Perm() != 0o600 {
		return nil, errors.New("state lock must be a regular mode 0600 file")
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		return nil, err
	}
	locked = true
	return file, nil
}

func releaseFileLock(file *os.File) {
	if file == nil {
		return
	}
	_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	_ = file.Close()
}

func (g *gate) captureLatestCredentialSnapshot() {
	if validateCredentialSet(g.options.authDir) != nil {
		return
	}
	instanceDir := filepath.Dir(g.credentialSnapshot)
	name := "credentials-latest-" + strconv.FormatInt(time.Now().UnixNano(), 10)
	path, err := copyCredentialSet(g.options.authDir, instanceDir, name)
	if err != nil || validateCredentialSet(path) != nil {
		if path != "" {
			_ = os.RemoveAll(path)
		}
		return
	}
	g.credentialSnapshot = path
}

func (g *gate) recoverCredentialSet() error {
	if validateCredentialSet(g.options.authDir) == nil {
		return nil
	}
	if g.credentialSnapshot == "" || validateCredentialSet(g.credentialSnapshot) != nil {
		return errors.New("verified credential snapshot is unavailable")
	}
	parent := filepath.Dir(g.options.authDir)
	nonce, err := randomHex(8)
	if err != nil {
		return err
	}
	broken := filepath.Join(parent, ".auth-invalid-"+nonce)
	if err := os.Rename(g.options.authDir, broken); err != nil {
		return err
	}
	// Freeze the invalid directory before selecting entries. A concurrent atomic login
	// promotion is then either included in `broken` or fails against the absent canonical
	// directory; it cannot report success and be silently lost by the recovery swap.
	recovery, err := buildRecoveryCredentialSet(
		broken,
		g.credentialSnapshot,
		parent,
		".auth-recovery-"+nonce,
	)
	if err != nil {
		_ = os.Rename(broken, g.options.authDir)
		return err
	}
	if err := os.Rename(recovery, g.options.authDir); err != nil {
		_ = os.Rename(broken, g.options.authDir)
		_ = os.RemoveAll(recovery)
		return err
	}
	if err := validateCredentialSet(g.options.authDir); err != nil {
		_ = os.RemoveAll(g.options.authDir)
		_ = os.Rename(broken, g.options.authDir)
		return fmt.Errorf("restored credential set failed validation: %w", err)
	}
	_ = os.RemoveAll(broken)
	return nil
}

func buildRecoveryCredentialSet(currentDir, snapshotDir, parentDir, name string) (string, error) {
	current, err := validCredentialEntriesByProvider(currentDir)
	if err != nil {
		return "", err
	}
	fallback, err := validCredentialEntriesByProvider(snapshotDir)
	if err != nil {
		return "", err
	}
	destination := filepath.Join(parentDir, name)
	if err := os.Mkdir(destination, 0o700); err != nil {
		return "", err
	}
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.RemoveAll(destination)
		}
	}()
	usedNames := make(map[string]bool)
	for _, provider := range []string{"codex", "claude"} {
		if len(current[provider]) > 1 {
			return "", fmt.Errorf("credential recovery has ambiguous current %s entries", provider)
		}
		candidates := fallback[provider]
		if len(current[provider]) == 1 {
			candidates = current[provider]
		}
		if len(candidates) == 0 {
			continue
		}
		if len(candidates) != 1 {
			return "", fmt.Errorf("credential recovery has ambiguous %s entries", provider)
		}
		entry := candidates[0]
		if usedNames[entry.name] {
			return "", errors.New("credential recovery has colliding entry names")
		}
		usedNames[entry.name] = true
		if err := writePrivateExclusive(filepath.Join(destination, entry.name), entry.raw); err != nil {
			return "", err
		}
	}
	if err := validateCredentialSet(destination); err != nil {
		return "", err
	}
	cleanup = false
	return destination, nil
}

func validCredentialEntriesByProvider(dir string) (map[string][]credentialEntry, error) {
	result := map[string][]credentialEntry{
		"codex":  nil,
		"claude": nil,
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		parsed, err := readCredentialEntry(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		result[parsed.provider] = append(result[parsed.provider], parsed)
	}
	return result, nil
}

func writePrivateExclusive(path string, raw []byte) error {
	file, err := os.OpenFile(
		path,
		os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		_ = file.Close()
		if !ok {
			_ = os.Remove(path)
		}
	}()
	if _, err := file.Write(raw); err != nil {
		return err
	}
	if err := file.Chmod(0o600); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	ok = true
	return nil
}

func copyCredentialSet(sourceDir, parentDir, name string) (string, error) {
	destination := filepath.Join(parentDir, name)
	if err := os.Mkdir(destination, 0o700); err != nil {
		return "", err
	}
	cleanup := true
	defer func() {
		if cleanup {
			_ = os.RemoveAll(destination)
		}
	}()
	entries, err := os.ReadDir(sourceDir)
	if err != nil {
		return "", err
	}
	for _, entry := range entries {
		source := filepath.Join(sourceDir, entry.Name())
		if err := assertPrivateRegular(source); err != nil {
			return "", err
		}
		raw, err := os.ReadFile(source)
		if err != nil {
			return "", err
		}
		if err := os.WriteFile(filepath.Join(destination, entry.Name()), raw, 0o600); err != nil {
			return "", err
		}
	}
	if err := validateCredentialSet(destination); err != nil {
		return "", err
	}
	cleanup = false
	return destination, nil
}

func (g *gate) signalChild(signal syscall.Signal) error {
	child := g.childCommand()
	if child == nil || child.Process == nil {
		return nil
	}
	if g.options.mode == "foreground" {
		return syscall.Kill(-child.Process.Pid, signal)
	}
	return child.Process.Signal(signal)
}

func (g *gate) failUnexpected(err error) {
	g.logf("claudex-gate: %v", err)
	g.mu.Lock()
	if g.state == "starting" {
		g.startupErr = err
		g.mu.Unlock()
		return
	}
	if g.state == "stopping" || g.state == "stopped" {
		g.mu.Unlock()
		return
	}
	g.state = "stopping"
	g.mu.Unlock()
	exitCode, stopError := g.stopProcess(true)
	if stopError == nil && exitCode == 0 {
		exitCode = 1
	}
	g.finish(exitCode)
}

func (g *gate) finish(exitCode int) {
	g.finishOnce.Do(func() {
		g.exitCode = exitCode
		close(g.done)
	})
}

func (g *gate) cleanup() {
	if g.publicServer != nil {
		_ = g.publicServer.Close()
	}
	if g.control != nil {
		_ = g.control.Close()
		if g.options.controlSocket != "" {
			_ = os.Remove(g.options.controlSocket)
		}
	}
	if g.lockFile != nil {
		_ = syscall.Flock(int(g.lockFile.Fd()), syscall.LOCK_UN)
		_ = g.lockFile.Close()
	}
	if g.logFile != nil {
		_ = g.logFile.Close()
		g.logFile = nil
	}
	if g.instanceDir != "" && validateCredentialSet(g.options.authDir) == nil {
		_ = os.RemoveAll(g.instanceDir)
	}
}

func (g *gate) openLog() (*os.File, error) {
	if err := rotateLog(g.options.logFile, 5<<20); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(g.options.logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return nil, err
	}
	g.logFile = file
	g.logger = log.New(file, "", log.LstdFlags)
	return file, nil
}

func (g *gate) logf(format string, args ...any) {
	if g.logger != nil {
		g.logger.Printf(format, args...)
		return
	}
	log.Printf(format, args...)
}

func runControl(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
	command := args[0]
	flags := flag.NewFlagSet("control "+command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	socket := flags.String("socket", "", "control socket")
	instance := flags.String("instance", "", "instance nonce")
	generation := flags.String("generation", "", "generation")
	timeout := flags.Int("timeout-seconds", 0, "drain timeout")
	force := flags.Bool("force", false, "force active cancellation")
	if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 || *socket == "" {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
	request := controlRequest{Command: command}
	switch command {
	case "inspect":
		if *instance != "" || *generation != "" || *timeout != 0 || *force {
			fmt.Fprint(os.Stderr, usage)
			return 2
		}
	case "drain-stop":
		if *instance == "" || *generation == "" || *timeout < 0 {
			fmt.Fprint(os.Stderr, usage)
			return 2
		}
		request.Instance = *instance
		request.Generation = *generation
		request.TimeoutSeconds = *timeout
		request.Force = *force
	default:
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
	connection, err := net.DialTimeout("unix", *socket, 2*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "claudex-gate: control unavailable: %v\n", err)
		return 1
	}
	defer connection.Close()
	if err := json.NewEncoder(connection).Encode(request); err != nil {
		fmt.Fprintf(os.Stderr, "claudex-gate: %v\n", err)
		return 1
	}
	var response controlResponse
	if err := json.NewDecoder(io.LimitReader(connection, 64<<10)).Decode(&response); err != nil {
		fmt.Fprintf(os.Stderr, "claudex-gate: %v\n", err)
		return 1
	}
	if command == "inspect" && response.Snapshot != nil {
		_ = json.NewEncoder(os.Stdout).Encode(response.Snapshot)
	} else {
		_ = json.NewEncoder(os.Stdout).Encode(response)
	}
	if !response.OK {
		return 1
	}
	return 0
}

func assertPrivateDir(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 {
		return fmt.Errorf("directory must be real and mode 0700: %s", path)
	}
	return nil
}

func assertPrivateRegular(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o600 {
		return fmt.Errorf("file must be regular and mode 0600: %s", path)
	}
	return nil
}

func validateCredentialSet(authDir string) error {
	if err := assertPrivateDir(authDir); err != nil {
		return errors.New("credential directory is unsafe")
	}
	entries, err := os.ReadDir(authDir)
	if err != nil {
		return err
	}
	codexCount := 0
	claudeCount := 0
	for _, entry := range entries {
		parsed, err := readCredentialEntry(filepath.Join(authDir, entry.Name()))
		if err != nil {
			return errors.New("credential set contains an invalid entry")
		}
		switch parsed.provider {
		case "codex":
			codexCount++
		case "claude":
			claudeCount++
		default:
			return errors.New("credential set contains an unsupported entry")
		}
	}
	if codexCount != 1 || claudeCount > 1 {
		return errors.New("credential set does not satisfy the default contract")
	}
	return nil
}

func readCredentialEntry(path string) (credentialEntry, error) {
	name := filepath.Base(path)
	// Keep the gate's recovery contract identical to the shell-side canonical
	// credential validator: every credential entry is a private JSON file.
	if filepath.Ext(name) != ".json" {
		return credentialEntry{}, errors.New("credential entry is not JSON")
	}
	if err := assertPrivateRegular(path); err != nil {
		return credentialEntry{}, errors.New("credential entry is unsafe")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return credentialEntry{}, err
	}
	var credential struct {
		Type         string `json:"type"`
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	if json.Unmarshal(raw, &credential) != nil || credential.AccessToken == "" || credential.RefreshToken == "" {
		return credentialEntry{}, errors.New("credential entry is invalid")
	}
	if credential.Type != "codex" && credential.Type != "claude" {
		return credentialEntry{}, errors.New("credential entry has unsupported type")
	}
	return credentialEntry{name: name, provider: credential.Type, raw: raw}, nil
}

func randomHex(bytes int) (string, error) {
	buffer := make([]byte, bytes)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func generateBackendCertificate(certPath, keyPath string) (*x509.CertPool, error) {
	now := time.Now()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          randomSerial(),
		Subject:               pkix.Name{CommonName: "claudex-private-ca"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(backendCertificateLifetime),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: randomSerial(),
		Subject:      pkix.Name{CommonName: "claudex-backend"},
		DNSNames:     []string{"claudex-backend"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		NotBefore:    now.Add(-time.Minute),
		NotAfter:     now.Add(backendCertificateLifetime),
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, caTemplate, &leafKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	leafKeyDER, err := x509.MarshalECPrivateKey(leafKey)
	if err != nil {
		return nil, err
	}
	certPEM := append(
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER}),
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})...,
	)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: leafKeyDER})
	if err := os.WriteFile(certPath, certPEM, 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})) {
		return nil, errors.New("failed to build backend CA pool")
	}
	return pool, nil
}

func randomSerial() *big.Int {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	value, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return big.NewInt(time.Now().UnixNano())
	}
	return value
}

func rotateLog(path string, maximum int64) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("refusing unsafe log path")
	}
	if info.Size() <= maximum {
		return nil
	}
	rotated := path + ".1"
	_ = os.Remove(rotated)
	return os.Rename(path, rotated)
}
