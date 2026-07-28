package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func buildGate(t *testing.T) string {
	t.Helper()
	binary := filepath.Join(t.TempDir(), "claudex-gate")
	cmd := exec.Command("go", "build", "-o", binary, ".")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("build claudex-gate: %v\n%s", err, output)
	}
	return binary
}

func TestHelpDocumentsPublicInternalCommands(t *testing.T) {
	binary := buildGate(t)
	output, err := exec.Command(binary, "--help").CombinedOutput()
	if err != nil {
		t.Fatalf("claudex-gate --help: %v\n%s", err, output)
	}
	text := string(output)
	for _, expected := range []string{
		"claudex-gate serve",
		"claudex-gate control inspect",
		"claudex-gate control drain-stop",
	} {
		if !strings.Contains(text, expected) {
			t.Fatalf("help is missing %q:\n%s", expected, text)
		}
	}
}

func freeAddress(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return address
}

func writePrivateFile(t *testing.T, path string, content []byte) {
	t.Helper()
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
}

func waitFor(t *testing.T, description string, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if check() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", description)
}

func TestManagedGateAuthenticatesAndDrainsBeforeChildStop(t *testing.T) {
	binary := buildGate(t)
	root, err := os.MkdirTemp("/tmp", "claudex-gate-test.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	stateDir := filepath.Join(root, "state")
	authDir := filepath.Join(stateDir, "auth")
	workDir := filepath.Join(stateDir, "work")
	for _, path := range []string{stateDir, authDir, workDir} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	publicKey := strings.Repeat("a", 64)
	publicKeyFile := filepath.Join(stateDir, "client-api-key")
	writePrivateFile(t, publicKeyFile, []byte(publicKey))
	credentialPath := filepath.Join(authDir, "codex.json")
	credentialBytes := []byte(`{"type":"codex","access_token":"access","refresh_token":"refresh"}`)
	writePrivateFile(t, credentialPath, credentialBytes)

	stopFile := filepath.Join(root, "child-stopped")
	requestLog := filepath.Join(root, "backend-requests")
	configFile := filepath.Join(stateDir, "config.json")
	config, err := json.Marshal(map[string]any{
		"host":                    "127.0.0.1",
		"port":                    1,
		"tls":                     map[string]any{"enable": false, "cert": "", "key": ""},
		"auth-dir":                authDir,
		"api-keys":                []string{publicKey},
		"test-stop-file":          stopFile,
		"test-request-log":        requestLog,
		"test-corrupt-credential": credentialPath,
	})
	if err != nil {
		t.Fatal(err)
	}
	writePrivateFile(t, configFile, config)

	helper := filepath.Join(root, "fake-backend")
	testBinary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	writePrivateFile(t, helper, []byte(fmt.Sprintf(
		"#!%s\nGO_WANT_CLAUDEX_BACKEND=1 exec %q -test.run '^TestGateBackendHelper$' -- \"$@\"\n",
		shell, testBinary,
	)))
	if err := os.Chmod(helper, 0o700); err != nil {
		t.Fatal(err)
	}

	publicAddress := freeAddress(t)
	backendAddress := freeAddress(t)
	socket := filepath.Join(stateDir, "control.sock")
	gate := exec.Command(
		binary, "serve",
		"--mode", "managed",
		"--state-dir", stateDir,
		"--auth-dir", authDir,
		"--work-dir", workDir,
		"--config", configFile,
		"--public-key-file", publicKeyFile,
		"--backend-bin", helper,
		"--generation", "test-generation",
		"--public-address", publicAddress,
		"--backend-address", backendAddress,
		"--control-socket", socket,
		"--drain-seconds", "5",
		"--child-stop-seconds", "2",
		"--log-file", filepath.Join(stateDir, "proxy.log"),
	)
	gateOutput := &strings.Builder{}
	gate.Stdout = gateOutput
	gate.Stderr = gateOutput
	if err := gate.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if gate.ProcessState == nil || !gate.ProcessState.Exited() {
			_ = gate.Process.Signal(syscall.SIGKILL)
			_ = gate.Wait()
		}
	})

	control := func(args ...string) ([]byte, error) {
		base := []string{"control"}
		base = append(base, args...)
		base = append(base, "--socket", socket)
		return exec.Command(binary, base...).CombinedOutput()
	}
	ready := false
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		output, err := control("inspect")
		if err == nil && strings.Contains(string(output), `"state":"open"`) {
			ready = true
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if !ready {
		t.Fatalf("timed out waiting for gate readiness:\n%s", gateOutput)
	}

	wrongRequest, err := http.NewRequest(http.MethodGet, "http://"+publicAddress+"/wrong", nil)
	if err != nil {
		t.Fatal(err)
	}
	wrongRequest.Header.Set("Authorization", "Bearer wrong")
	wrongResponse, err := http.DefaultClient.Do(wrongRequest)
	if err != nil {
		t.Fatal(err)
	}
	_ = wrongResponse.Body.Close()
	if wrongResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong credential status = %d", wrongResponse.StatusCode)
	}
	loggedRequests, err := os.ReadFile(requestLog)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(loggedRequests), "/wrong") {
		t.Fatal("unauthorized request reached backend")
	}

	releaseFile := filepath.Join(root, "release")
	streamURL := "http://" + publicAddress + "/stream?release=" + releaseFile
	streamRequest, err := http.NewRequest(http.MethodGet, streamURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	streamRequest.Header.Set("Authorization", "Bearer "+publicKey)
	streamResponse, err := http.DefaultClient.Do(streamRequest)
	if err != nil {
		t.Fatal(err)
	}
	first := make([]byte, 5)
	if _, err := io.ReadFull(streamResponse.Body, first); err != nil {
		t.Fatal(err)
	}
	if string(first) != "begin" {
		t.Fatalf("unexpected stream prefix %q", first)
	}

	inspectOutput, err := control("inspect")
	if err != nil {
		t.Fatalf("inspect: %v\n%s", err, inspectOutput)
	}
	var snapshot struct {
		Instance   string `json:"instance"`
		Generation string `json:"generation"`
		Active     int    `json:"active"`
	}
	if err := json.Unmarshal(inspectOutput, &snapshot); err != nil {
		t.Fatalf("inspect JSON: %v\n%s", err, inspectOutput)
	}
	if snapshot.Active != 1 {
		t.Fatalf("active = %d, want 1", snapshot.Active)
	}

	drain := exec.Command(
		binary, "control", "drain-stop",
		"--socket", socket,
		"--instance", snapshot.Instance,
		"--generation", snapshot.Generation,
		"--timeout-seconds", "5",
	)
	drainOutput := &strings.Builder{}
	drain.Stdout = drainOutput
	drain.Stderr = drainOutput
	if err := drain.Start(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "draining state", func() bool {
		output, err := control("inspect")
		return err == nil && strings.Contains(string(output), `"state":"draining"`)
	})
	if _, err := os.Stat(stopFile); !os.IsNotExist(err) {
		t.Fatalf("child stopped before active request completed: %v", err)
	}

	blockedRequest, _ := http.NewRequest(http.MethodGet, "http://"+publicAddress+"/blocked", nil)
	blockedRequest.Header.Set("Authorization", "Bearer "+publicKey)
	blockedResponse, err := http.DefaultClient.Do(blockedRequest)
	if err != nil {
		t.Fatal(err)
	}
	_ = blockedResponse.Body.Close()
	if blockedResponse.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("request admitted while draining: %d", blockedResponse.StatusCode)
	}

	writePrivateFile(t, releaseFile, []byte("go"))
	rest, err := io.ReadAll(streamResponse.Body)
	if err != nil {
		t.Fatal(err)
	}
	_ = streamResponse.Body.Close()
	if string(rest) != "end" {
		t.Fatalf("unexpected stream suffix %q", rest)
	}
	if err := drain.Wait(); err != nil {
		t.Fatalf("drain-stop: %v\n%s", err, drainOutput)
	}
	if err := gate.Wait(); err != nil {
		t.Fatalf("gate exit: %v\n%s", err, gateOutput)
	}
	waitFor(t, "child stop marker", func() bool {
		_, err := os.Stat(stopFile)
		return err == nil
	})
	restoredCredential, err := os.ReadFile(credentialPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(restoredCredential) != string(credentialBytes) {
		t.Fatalf("credential was not restored after child corruption: %s", restoredCredential)
	}
}

func TestGateBackendHelper(t *testing.T) {
	if os.Getenv("GO_WANT_CLAUDEX_BACKEND") != "1" {
		return
	}
	args := os.Args
	separator := -1
	for i, arg := range args {
		if arg == "--" {
			separator = i
			break
		}
	}
	if separator < 0 {
		os.Exit(90)
	}
	configPath := ""
	for i := separator + 1; i < len(args); i++ {
		if args[i] == "--config" && i+1 < len(args) {
			configPath = args[i+1]
			i++
		}
	}
	raw, err := os.ReadFile(configPath)
	if err != nil {
		os.Exit(91)
	}
	var config map[string]any
	if json.Unmarshal(raw, &config) != nil {
		os.Exit(92)
	}
	host, _ := config["host"].(string)
	port, _ := config["port"].(float64)
	tlsConfig, _ := config["tls"].(map[string]any)
	certPath, _ := tlsConfig["cert"].(string)
	keyPath, _ := tlsConfig["key"].(string)
	keys, _ := config["api-keys"].([]any)
	key := ""
	if len(keys) == 1 {
		key, _ = keys[0].(string)
	}
	stopFile, _ := config["test-stop-file"].(string)
	requestLog, _ := config["test-request-log"].(string)
	corruptCredential, _ := config["test-corrupt-credential"].(string)

	handler := http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Header.Get("Authorization") != "Bearer "+key {
			http.Error(writer, "unauthorized", http.StatusUnauthorized)
			return
		}
		file, err := os.OpenFile(requestLog, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
		if err == nil {
			_, _ = fmt.Fprintln(file, request.URL.Path)
			_ = file.Close()
		}
		if request.URL.Path == "/v1/models" {
			writer.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(writer, `{"data":[{"id":"gpt-5.6-sol"}]}`)
			return
		}
		if request.URL.Path == "/stream" {
			_, _ = io.WriteString(writer, "begin")
			if flusher, ok := writer.(http.Flusher); ok {
				flusher.Flush()
			}
			release := request.URL.Query().Get("release")
			for {
				if _, err := os.Stat(release); err == nil {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			_, _ = io.WriteString(writer, "end")
			return
		}
		_, _ = io.WriteString(writer, "ok")
	})
	server := &http.Server{Handler: handler}
	listener, err := tls.Listen(
		"tcp",
		net.JoinHostPort(host, strconv.Itoa(int(port))),
		&tls.Config{Certificates: mustLoadCertificate(certPath, keyPath), MinVersion: tls.VersionTLS12},
	)
	if err != nil {
		os.Exit(93)
	}
	signals := make(chan os.Signal, 1)
	signalNotify(signals)
	go func() {
		<-signals
		if corruptCredential != "" {
			_ = os.WriteFile(corruptCredential, []byte(`{"type":"codex"}`), 0o600)
		}
		writePrivateFileForHelper(stopFile)
		_ = server.Shutdown(context.Background())
	}()
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		os.Exit(94)
	}
	os.Exit(0)
}

func mustLoadCertificate(certPath, keyPath string) []tls.Certificate {
	certificate, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		os.Exit(95)
	}
	return []tls.Certificate{certificate}
}

func signalNotify(ch chan<- os.Signal) {
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT)
}

func writePrivateFileForHelper(path string) {
	_ = os.WriteFile(path, []byte("stopped"), 0o600)
}
