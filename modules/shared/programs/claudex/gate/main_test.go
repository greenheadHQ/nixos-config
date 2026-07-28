package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
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
	"sync/atomic"
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

func TestReleaseStartupLockUnlocksInheritedDescriptor(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lifecycle.lock")
	fd, err := syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = syscall.Close(fd)
		t.Fatal(err)
	}
	runtime := &gate{options: serveOptions{startupLockFD: fd}}
	if err := runtime.releaseStartupLock(); err != nil {
		t.Fatal(err)
	}
	if runtime.options.startupLockFD != -1 {
		t.Fatalf("startup lock descriptor = %d, want released", runtime.options.startupLockFD)
	}

	probe, err := syscall.Open(path, syscall.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(probe)
	if err := syscall.Flock(probe, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("released lifecycle lock remained held: %v", err)
	}
}

func TestValidateServeOptionsAllowsManagedStartupLock(t *testing.T) {
	options := serveOptions{
		mode:           "managed",
		stateDir:       "/state",
		authDir:        "/state/auth",
		workDir:        "/state/work",
		configFile:     "/state/config",
		publicKeyFile:  "/state/key",
		backendBin:     "/backend",
		generation:     "generation",
		publicAddress:  "127.0.0.1:8317",
		backendAddress: "127.0.0.1:8318",
		controlSocket:  "/state/control.sock",
		logFile:        "/state/proxy.log",
		home:           "/home",
		startupLockFD:  8,
	}
	if err := validateServeOptions(&options); err != nil {
		t.Fatalf("managed startup lock was rejected: %v", err)
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

func TestGateDiagnosticsFollowRotatedLog(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "proxy.log")
	writePrivateFile(t, logPath, []byte("old-log"))
	if err := os.Truncate(logPath, (5<<20)+1); err != nil {
		t.Fatal(err)
	}
	runtime := &gate{options: serveOptions{logFile: logPath}}
	if _, err := runtime.openLog(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { runtime.cleanup() })

	const diagnostic = "post-rotation gate diagnostic"
	runtime.logf("%s", diagnostic)
	if err := runtime.logFile.Sync(); err != nil {
		t.Fatal(err)
	}
	current, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(current), diagnostic) {
		t.Fatalf("current proxy log does not contain gate diagnostic: %q", current)
	}
	rotated, err := os.ReadFile(logPath + ".1")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(rotated), diagnostic) {
		t.Fatal("gate diagnostic was written to the rotated manager log")
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

func TestValidateCredentialSetRejectsNonJSONEntry(t *testing.T) {
	authDir := t.TempDir()
	writePrivateFile(
		t,
		filepath.Join(authDir, "codex-credential"),
		[]byte(`{"type":"codex","access_token":"access","refresh_token":"refresh"}`),
	)
	if err := validateCredentialSet(authDir); err == nil {
		t.Fatal("credential set accepted a non-.json entry that the shell validator rejects")
	}
}

func TestDrainStopReportsCredentialRecoveryFailure(t *testing.T) {
	stateDir := t.TempDir()
	authDir := filepath.Join(stateDir, "auth")
	if err := os.Mkdir(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writePrivateFile(t, filepath.Join(authDir, "codex.json"), []byte(`{"type":"codex"}`))
	runtime := &gate{
		options: serveOptions{
			mode:     "managed",
			stateDir: stateDir,
			authDir:  authDir,
		},
		state:         "open",
		instance:      "test-instance",
		activeCancels: make(map[uint64]context.CancelFunc),
		stopped:       make(chan struct{}),
		done:          make(chan struct{}),
	}
	server, client := net.Pipe()
	t.Cleanup(func() {
		_ = server.Close()
		_ = client.Close()
	})
	go runtime.handleControl(server)
	request := controlRequest{
		Command:        "drain-stop",
		Instance:       runtime.instance,
		Generation:     runtime.options.generation,
		TimeoutSeconds: 0,
	}
	if err := json.NewEncoder(client).Encode(request); err != nil {
		t.Fatal(err)
	}
	var response controlResponse
	if err := json.NewDecoder(client).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.OK || response.Code != "RECOVERY_FAILED" {
		t.Fatalf("recovery failure response = %+v", response)
	}
	select {
	case <-runtime.done:
	case <-time.After(time.Second):
		t.Fatal("gate did not finish after reporting credential recovery failure")
	}
	if runtime.exitCode != 0 {
		t.Fatalf("recovery failure exit = %d, want restart-suppressing 0", runtime.exitCode)
	}
}

func TestSignalDuringControlDrainNeverReopensAdmission(t *testing.T) {
	stateDir := t.TempDir()
	runtime := &gate{
		options: serveOptions{
			mode:         "managed",
			stateDir:     stateDir,
			drainSeconds: 2,
		},
		state:         "open",
		instance:      "test-instance",
		active:        1,
		activeCancels: make(map[uint64]context.CancelFunc),
		stopped:       make(chan struct{}),
		done:          make(chan struct{}),
	}
	disconnected := make(chan struct{})
	type result struct {
		response  controlResponse
		committed bool
	}
	resultCh := make(chan result, 1)
	go func() {
		response, committed := runtime.drainAndStop(
			controlRequest{
				Instance:       runtime.instance,
				Generation:     runtime.options.generation,
				TimeoutSeconds: 5,
			},
			disconnected,
		)
		resultCh <- result{response: response, committed: committed}
	}()
	waitFor(t, "control drain", func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return runtime.state == "draining" && runtime.drainZero != nil
	})

	signalDone := make(chan struct{})
	go func() {
		runtime.stopFromSignal()
		close(signalDone)
	}()
	waitFor(t, "terminal signal intent", func() bool {
		runtime.mu.Lock()
		defer runtime.mu.Unlock()
		return runtime.terminalStop
	})
	close(disconnected)

	select {
	case drainResult := <-resultCh:
		if drainResult.committed || drainResult.response.Code != "STOPPING" {
			t.Fatalf("overlapped control drain result = %+v", drainResult)
		}
	case <-time.After(time.Second):
		t.Fatal("control drain did not observe the overlapping signal")
	}
	runtime.mu.Lock()
	if runtime.state == "open" {
		runtime.mu.Unlock()
		t.Fatal("control disconnect reopened admission after terminal signal")
	}
	zero := runtime.drainZero
	runtime.active = 0
	runtime.drainZero = nil
	close(zero)
	runtime.mu.Unlock()

	select {
	case <-signalDone:
	case <-time.After(time.Second):
		t.Fatal("signal shutdown did not finish after active requests drained")
	}
	runtime.mu.Lock()
	defer runtime.mu.Unlock()
	if runtime.state != "stopped" {
		t.Fatalf("terminal shutdown state = %q, want stopped", runtime.state)
	}
}

func TestRecoveryFailureSuppressesUnexpectedRestart(t *testing.T) {
	stateDir := t.TempDir()
	authDir := filepath.Join(stateDir, "auth")
	if err := os.Mkdir(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writePrivateFile(t, filepath.Join(authDir, "codex.json"), []byte(`{"type":"codex"}`))
	runtime := &gate{
		options: serveOptions{
			mode:     "managed",
			stateDir: stateDir,
			authDir:  authDir,
		},
		state:         "open",
		activeCancels: make(map[uint64]context.CancelFunc),
		stopped:       make(chan struct{}),
		done:          make(chan struct{}),
	}
	runtime.failUnexpected(errors.New("test failure"))
	if runtime.exitCode != 0 {
		t.Fatalf("recovery failure exit = %d, want restart-suppressing 0", runtime.exitCode)
	}
}

func TestCredentialRecoveryPreservesNewValidSibling(t *testing.T) {
	root := t.TempDir()
	authDir := filepath.Join(root, "auth")
	if err := os.Mkdir(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	oldCodex := []byte(`{"type":"codex","access_token":"old-access","refresh_token":"old-refresh"}`)
	newClaude := []byte(`{"type":"claude","access_token":"new-access","refresh_token":"new-refresh"}`)
	codexPath := filepath.Join(authDir, "codex.json")
	claudePath := filepath.Join(authDir, "claude-added.json")
	writePrivateFile(t, codexPath, oldCodex)
	snapshot, err := copyCredentialSet(authDir, root, "snapshot")
	if err != nil {
		t.Fatal(err)
	}
	writePrivateFile(t, claudePath, newClaude)
	writePrivateFile(t, codexPath, []byte(`{"type":"codex"}`))

	runtime := &gate{
		options:            serveOptions{authDir: authDir},
		credentialSnapshot: snapshot,
	}
	if err := runtime.recoverCredentialSet(); err != nil {
		t.Fatal(err)
	}
	restoredCodex, err := os.ReadFile(codexPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(restoredCodex) != string(oldCodex) {
		t.Fatalf("codex fallback changed: %s", restoredCodex)
	}
	preservedClaude, err := os.ReadFile(claudePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(preservedClaude) != string(newClaude) {
		t.Fatalf("new valid sibling changed: %s", preservedClaude)
	}
	if err := validateCredentialSet(authDir); err != nil {
		t.Fatalf("recovered credential set is invalid: %v", err)
	}
}

func TestCredentialRecoveryPreservesAmbiguousCurrentProvider(t *testing.T) {
	root := t.TempDir()
	authDir := filepath.Join(root, "auth")
	if err := os.Mkdir(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	first := []byte(`{"type":"codex","access_token":"current-one","refresh_token":"refresh-one"}`)
	second := []byte(`{"type":"codex","access_token":"current-two","refresh_token":"refresh-two"}`)
	firstPath := filepath.Join(authDir, "codex-one.json")
	secondPath := filepath.Join(authDir, "codex-two.json")
	writePrivateFile(t, firstPath, first)
	writePrivateFile(t, secondPath, second)
	snapshotDir := filepath.Join(root, "snapshot")
	if err := os.Mkdir(snapshotDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writePrivateFile(
		t,
		filepath.Join(snapshotDir, "codex.json"),
		[]byte(`{"type":"codex","access_token":"snapshot","refresh_token":"snapshot-refresh"}`),
	)

	runtime := &gate{
		options:            serveOptions{authDir: authDir},
		credentialSnapshot: snapshotDir,
	}
	if err := runtime.recoverCredentialSet(); err == nil {
		t.Fatal("credential recovery silently selected a fallback over ambiguous current credentials")
	}
	for path, expected := range map[string][]byte{firstPath: first, secondPath: second} {
		actual, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("ambiguous current credential was not restored: %v", err)
		}
		if string(actual) != string(expected) {
			t.Fatalf("ambiguous current credential changed: %s", actual)
		}
	}
}

func TestCredentialRecoveryWaitsForCanonicalStateLock(t *testing.T) {
	stateDir := t.TempDir()
	authDir := filepath.Join(stateDir, "auth")
	if err := os.Mkdir(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writePrivateFile(t, filepath.Join(authDir, "codex.json"), []byte(`{"type":"codex"}`))
	snapshotDir := filepath.Join(stateDir, "snapshot")
	if err := os.Mkdir(snapshotDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writePrivateFile(
		t,
		filepath.Join(snapshotDir, "codex.json"),
		[]byte(`{"type":"codex","access_token":"snapshot-access","refresh_token":"snapshot-refresh"}`),
	)
	lockPath := filepath.Join(stateDir, "state.lock")
	ready := filepath.Join(stateDir, "lock-ready")
	holder := exec.Command(os.Args[0], "-test.run", "^TestGateStateLockHolderHelper$")
	holder.Env = append(
		os.Environ(),
		"GO_WANT_CLAUDEX_STATE_LOCK_HOLDER=1",
		"CLAUDEX_TEST_STATE_LOCK="+lockPath,
		"CLAUDEX_TEST_STATE_LOCK_READY="+ready,
	)
	holderInput, err := holder.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	holderOutput := &strings.Builder{}
	holder.Stdout = holderOutput
	holder.Stderr = holderOutput
	if err := holder.Start(); err != nil {
		t.Fatal(err)
	}
	holderWaited := false
	t.Cleanup(func() {
		if !holderWaited && (holder.ProcessState == nil || !holder.ProcessState.Exited()) {
			_ = holderInput.Close()
			_ = holder.Process.Kill()
			_ = holder.Wait()
		}
	})
	waitFor(t, "external state-lock holder", func() bool {
		_, err := os.Stat(ready)
		return err == nil
	})
	runtime := &gate{
		options: serveOptions{
			mode:     "managed",
			stateDir: stateDir,
			authDir:  authDir,
		},
		state:              "stopping",
		activeCancels:      make(map[uint64]context.CancelFunc),
		credentialSnapshot: snapshotDir,
		stopped:            make(chan struct{}),
		done:               make(chan struct{}),
	}
	result := make(chan error, 1)
	go func() {
		_, err := runtime.stopProcess(false)
		result <- err
	}()
	select {
	case err := <-result:
		t.Fatalf("credential recovery bypassed the held state lock: %v", err)
	case <-time.After(100 * time.Millisecond):
	}
	if _, err := os.Stat(authDir); err != nil {
		t.Fatalf("credential directory changed while the state lock was held: %v", err)
	}
	matches, err := filepath.Glob(filepath.Join(stateDir, ".auth-invalid-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatal("credential recovery renamed auth while the state lock was held")
	}
	if err := holderInput.Close(); err != nil {
		t.Fatal(err)
	}
	if err := holder.Wait(); err != nil {
		t.Fatalf("state-lock holder exit: %v\n%s", err, holderOutput)
	}
	holderWaited = true

	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("credential recovery did not resume after the state lock was released")
	}
	if err := validateCredentialSet(authDir); err != nil {
		t.Fatalf("recovered credential set is invalid: %v", err)
	}
}

func TestGateStateLockHolderHelper(t *testing.T) {
	if os.Getenv("GO_WANT_CLAUDEX_STATE_LOCK_HOLDER") != "1" {
		return
	}
	path := os.Getenv("CLAUDEX_TEST_STATE_LOCK")
	ready := os.Getenv("CLAUDEX_TEST_STATE_LOCK_READY")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	if err := os.WriteFile(ready, []byte("ready"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, os.Stdin)
}

func TestCleanupDoesNotRemoveAnotherGateControlSocket(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "claudex-control-owner-test.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	socket := filepath.Join(root, "control.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	competing := &gate{options: serveOptions{controlSocket: socket}}
	competing.cleanup()
	if _, err := os.Lstat(socket); err != nil {
		t.Fatalf("unowned live control socket was removed: %v", err)
	}
	connection, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatalf("original control listener stopped accepting connections: %v", err)
	}
	_ = connection.Close()
}

func TestBindControlReplacesStaleSocket(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "claudex-stale-socket-test.")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	socket := filepath.Join(root, "control.sock")
	stale, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	unixStale, ok := stale.(*net.UnixListener)
	if !ok {
		t.Fatal("Unix listener has an unexpected type")
	}
	unixStale.SetUnlinkOnClose(false)
	if err := stale.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(socket); err != nil {
		t.Fatalf("stale socket fixture is missing: %v", err)
	}

	runtime := &gate{
		options: serveOptions{controlSocket: socket},
		stopped: make(chan struct{}),
		done:    make(chan struct{}),
	}
	if err := runtime.bindControl(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		close(runtime.stopped)
		runtime.cleanup()
	})
	connection, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatalf("replacement control listener is unreachable: %v", err)
	}
	_ = connection.Close()
}

func TestCleanBackendExitAfterReadinessTriggersRestart(t *testing.T) {
	root := t.TempDir()
	authDir := filepath.Join(root, "auth")
	if err := os.Mkdir(authDir, 0o700); err != nil {
		t.Fatal(err)
	}
	writePrivateFile(
		t,
		filepath.Join(authDir, "codex.json"),
		[]byte(`{"type":"codex","access_token":"access","refresh_token":"refresh"}`),
	)
	snapshot, err := copyCredentialSet(authDir, root, "snapshot")
	if err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(root, "clean-backend")
	writePrivateFile(t, helper, []byte("#!/bin/sh\nexit 0\n"))
	if err := os.Chmod(helper, 0o700); err != nil {
		t.Fatal(err)
	}
	logFile, err := os.OpenFile(filepath.Join(root, "proxy.log"), os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = logFile.Close() })
	runtime := &gate{
		options: serveOptions{
			mode:             "managed",
			stateDir:         root,
			authDir:          authDir,
			workDir:          root,
			home:             root,
			backendBin:       helper,
			childStopSeconds: 1,
		},
		state:              "open",
		activeCancels:      make(map[uint64]context.CancelFunc),
		credentialSnapshot: snapshot,
		childConfig:        "",
		childDone:          make(chan struct{}),
		stopped:            make(chan struct{}),
		done:               make(chan struct{}),
	}
	if err := runtime.startChild(logFile); err != nil {
		t.Fatal(err)
	}
	select {
	case <-runtime.done:
	case <-time.After(3 * time.Second):
		t.Fatal("gate did not stop after a clean backend exit")
	}
	if runtime.exitCode != 1 {
		t.Fatalf("unexpected clean backend exit produced gate exit %d, want 1", runtime.exitCode)
	}
	if !runtime.unexpectedChild {
		t.Fatal("unexpected clean backend exit was not classified as a crash")
	}
}

func TestForegroundStartupSIGINTStopsChildGroup(t *testing.T) {
	binary := buildGate(t)
	root, err := os.MkdirTemp("/tmp", "claudex-startup-signal-test.")
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
	publicKeyFile := filepath.Join(stateDir, "client-api-key")
	writePrivateFile(t, publicKeyFile, []byte(strings.Repeat("d", 64)))
	writePrivateFile(
		t,
		filepath.Join(authDir, "codex.json"),
		[]byte(`{"type":"codex","access_token":"access","refresh_token":"refresh"}`),
	)
	configFile := filepath.Join(stateDir, "config.json")
	writePrivateFile(t, configFile, []byte(`{}`))
	started := filepath.Join(root, "child-started")
	stopped := filepath.Join(root, "child-stopped")
	helper := filepath.Join(root, "slow-backend")
	writePrivateFile(t, helper, []byte(fmt.Sprintf(
		`#!/bin/sh
started=%q
stopped=%q
trap 'printf stopped > "$stopped"; exit 0' TERM INT
printf '%%s' "$$" > "$started"
while :; do /bin/sleep 1; done
`,
		started,
		stopped,
	)))
	if err := os.Chmod(helper, 0o700); err != nil {
		t.Fatal(err)
	}

	socket := filepath.Join(stateDir, "control.sock")
	gate := exec.Command(
		binary, "serve",
		"--mode", "foreground",
		"--state-dir", stateDir,
		"--auth-dir", authDir,
		"--work-dir", workDir,
		"--config", configFile,
		"--public-key-file", publicKeyFile,
		"--backend-bin", helper,
		"--generation", "test-generation",
		"--public-address", freeAddress(t),
		"--backend-address", freeAddress(t),
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
	childPID := 0
	gateWaited := false
	t.Cleanup(func() {
		if childPID > 0 {
			_ = syscall.Kill(-childPID, syscall.SIGKILL)
		}
		if !gateWaited && (gate.ProcessState == nil || !gate.ProcessState.Exited()) {
			_ = gate.Process.Signal(syscall.SIGKILL)
			_ = gate.Wait()
		}
	})
	waitFor(t, "foreground startup child", func() bool {
		raw, err := os.ReadFile(started)
		if err != nil {
			return false
		}
		childPID, err = strconv.Atoi(strings.TrimSpace(string(raw)))
		return err == nil && childPID > 0
	})
	if err := gate.Process.Signal(syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	if err := gate.Wait(); err != nil {
		t.Fatalf("startup SIGINT did not produce a clean gate exit: %v\n%s", err, gateOutput)
	}
	gateWaited = true
	waitFor(t, "startup child stop marker", func() bool {
		_, err := os.Stat(stopped)
		return err == nil
	})
	if err := syscall.Kill(-childPID, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("foreground child group survived startup SIGINT: %v", err)
	}
	if _, err := os.Lstat(socket); !os.IsNotExist(err) {
		t.Fatalf("control socket survived startup SIGINT cleanup: %v", err)
	}
}

func TestWrongCertificateReceivesNoBackendCredentialOrBody(t *testing.T) {
	root := t.TempDir()
	stateDir := filepath.Join(root, "state")
	authDir := filepath.Join(stateDir, "auth")
	for _, path := range []string{stateDir, authDir} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	writePrivateFile(
		t,
		filepath.Join(authDir, "codex.json"),
		[]byte(`{"type":"codex","access_token":"access","refresh_token":"refresh"}`),
	)
	configFile := filepath.Join(stateDir, "config.json")
	writePrivateFile(t, configFile, []byte(`{}`))

	attackerCert := filepath.Join(root, "attacker-cert.pem")
	attackerKey := filepath.Join(root, "attacker-key.pem")
	if _, err := generateBackendCertificate(attackerCert, attackerKey); err != nil {
		t.Fatal(err)
	}
	rawListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	attackerListener := tls.NewListener(rawListener, &tls.Config{
		Certificates: mustLoadCertificate(attackerCert, attackerKey),
		MinVersion:   tls.VersionTLS12,
	})
	var requests atomic.Int64
	var authorizationBytes atomic.Int64
	var bodyBytes atomic.Int64
	attacker := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		authorizationBytes.Add(int64(len(request.Header.Get("Authorization"))))
		raw, _ := io.ReadAll(request.Body)
		bodyBytes.Add(int64(len(raw)))
		writer.WriteHeader(http.StatusOK)
	})}
	go func() { _ = attacker.Serve(attackerListener) }()
	t.Cleanup(func() { _ = attacker.Close() })

	publicKey := strings.Repeat("b", 64)
	runtime, err := newGate(serveOptions{
		stateDir:       stateDir,
		authDir:        authDir,
		configFile:     configFile,
		backendAddress: rawListener.Addr().String(),
		publicAddress:  freeAddress(t),
	})
	if err != nil {
		t.Fatal(err)
	}
	runtime.publicKey = publicKey
	if err := runtime.prepareBackend(); err != nil {
		t.Fatal(err)
	}
	runtime.state = "open"
	if err := runtime.bindPublic(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(runtime.cleanup)

	request, err := http.NewRequest(
		http.MethodPost,
		"http://"+runtime.publicListener.Addr().String()+"/secret",
		bytes.NewBufferString("private-request-body"),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+publicKey)
	client := &http.Client{Timeout: 10 * time.Second}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusBadGateway {
		t.Fatalf("wrong-certificate backend status = %d, want 502", response.StatusCode)
	}
	if requests.Load() != 0 || authorizationBytes.Load() != 0 || bodyBytes.Load() != 0 {
		t.Fatalf(
			"wrong-certificate backend received requests=%d authorization_bytes=%d body_bytes=%d",
			requests.Load(),
			authorizationBytes.Load(),
			bodyBytes.Load(),
		)
	}
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
	writePrivateFile(t, helper, []byte(fmt.Sprintf(
		"#!/bin/sh\nGO_WANT_CLAUDEX_BACKEND=1 exec %q -test.run '^TestGateBackendHelper$' -- \"$@\"\n",
		testBinary,
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
	if err != nil && !os.IsNotExist(err) {
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

func TestForegroundSIGINTDrainsBeforeStoppingChildProcessGroup(t *testing.T) {
	binary := buildGate(t)
	root, err := os.MkdirTemp("/tmp", "claudex-foreground-test.")
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
	publicKey := strings.Repeat("c", 64)
	publicKeyFile := filepath.Join(stateDir, "client-api-key")
	writePrivateFile(t, publicKeyFile, []byte(publicKey))
	writePrivateFile(
		t,
		filepath.Join(authDir, "codex.json"),
		[]byte(`{"type":"codex","access_token":"access","refresh_token":"refresh"}`),
	)

	stopFile := filepath.Join(root, "child-stopped")
	memberReady := filepath.Join(root, "group-member-ready")
	memberStopped := filepath.Join(root, "group-member-stopped")
	requestLog := filepath.Join(root, "backend-requests")
	configFile := filepath.Join(stateDir, "config.json")
	config, err := json.Marshal(map[string]any{
		"host":                      "127.0.0.1",
		"port":                      1,
		"tls":                       map[string]any{"enable": false, "cert": "", "key": ""},
		"auth-dir":                  authDir,
		"api-keys":                  []string{publicKey},
		"test-stop-file":            stopFile,
		"test-request-log":          requestLog,
		"test-group-member-ready":   memberReady,
		"test-group-member-stopped": memberStopped,
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
	writePrivateFile(t, helper, []byte(fmt.Sprintf(
		"#!/bin/sh\nGO_WANT_CLAUDEX_BACKEND=1 exec %q -test.run '^TestGateBackendHelper$' -- \"$@\"\n",
		testBinary,
	)))
	if err := os.Chmod(helper, 0o700); err != nil {
		t.Fatal(err)
	}

	publicAddress := freeAddress(t)
	backendAddress := freeAddress(t)
	socket := filepath.Join(stateDir, "control.sock")
	gate := exec.Command(
		binary, "serve",
		"--mode", "foreground",
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
	gateWaited := false
	backendProcessGroup := 0
	t.Cleanup(func() {
		if backendProcessGroup > 0 {
			_ = syscall.Kill(-backendProcessGroup, syscall.SIGKILL)
		}
		if !gateWaited && (gate.ProcessState == nil || !gate.ProcessState.Exited()) {
			_ = gate.Process.Signal(syscall.SIGKILL)
			_ = gate.Wait()
		}
	})

	control := func() ([]byte, error) {
		return exec.Command(binary, "control", "inspect", "--socket", socket).CombinedOutput()
	}
	var current snapshot
	waitFor(t, "foreground gate and child group member readiness", func() bool {
		output, err := control()
		if err != nil || json.Unmarshal(output, &current) != nil || current.State != "open" {
			return false
		}
		_, err = os.Stat(memberReady)
		return err == nil
	})
	memberRaw, err := os.ReadFile(memberReady)
	if err != nil {
		t.Fatal(err)
	}
	memberPID, err := strconv.Atoi(strings.TrimSpace(string(memberRaw)))
	if err != nil {
		t.Fatal(err)
	}
	backendProcessGroup, err = syscall.Getpgid(current.BackendPID)
	if err != nil {
		t.Fatal(err)
	}
	memberProcessGroup, err := syscall.Getpgid(memberPID)
	if err != nil {
		t.Fatal(err)
	}
	gateProcessGroup, err := syscall.Getpgid(current.GatePID)
	if err != nil {
		t.Fatal(err)
	}
	if backendProcessGroup != current.BackendPID || memberProcessGroup != backendProcessGroup {
		t.Fatalf(
			"foreground child group mismatch: backend_pid=%d backend_pgid=%d member_pgid=%d",
			current.BackendPID,
			backendProcessGroup,
			memberProcessGroup,
		)
	}
	if gateProcessGroup == backendProcessGroup {
		t.Fatal("foreground backend still shares the gate process group")
	}

	releaseFile := filepath.Join(root, "release")
	streamRequest, err := http.NewRequest(
		http.MethodGet,
		"http://"+publicAddress+"/stream?release="+releaseFile,
		nil,
	)
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
	waitFor(t, "active foreground request", func() bool {
		output, err := control()
		return err == nil && json.Unmarshal(output, &current) == nil && current.Active == 1
	})

	if err := gate.Process.Signal(syscall.SIGINT); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "foreground draining state", func() bool {
		output, err := control()
		return err == nil && strings.Contains(string(output), `"state":"draining"`)
	})
	for _, marker := range []string{stopFile, memberStopped} {
		if _, err := os.Stat(marker); !os.IsNotExist(err) {
			t.Fatalf("child process group stopped before active request drained: %s", marker)
		}
	}
	if err := syscall.Kill(-backendProcessGroup, 0); err != nil {
		t.Fatalf("child process group is not alive while draining: %v", err)
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
	if err := gate.Wait(); err != nil {
		t.Fatalf("foreground gate exit: %v\n%s", err, gateOutput)
	}
	gateWaited = true
	waitFor(t, "foreground child process-group stop markers", func() bool {
		_, leaderErr := os.Stat(stopFile)
		_, memberErr := os.Stat(memberStopped)
		return leaderErr == nil && memberErr == nil
	})
	if err := syscall.Kill(-backendProcessGroup, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("foreground child process group survived gate exit: %v", err)
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
	groupMemberReady, _ := config["test-group-member-ready"].(string)
	groupMemberStopped, _ := config["test-group-member-stopped"].(string)
	var groupMember *exec.Cmd
	if groupMemberReady != "" {
		testBinary, err := os.Executable()
		if err != nil {
			os.Exit(96)
		}
		groupMember = exec.Command(testBinary, "-test.run", "^TestGateGroupMemberHelper$")
		groupMember.Env = append(
			os.Environ(),
			"GO_WANT_CLAUDEX_GROUP_MEMBER=1",
			"CLAUDEX_GROUP_MEMBER_READY="+groupMemberReady,
			"CLAUDEX_GROUP_MEMBER_STOPPED="+groupMemberStopped,
		)
		if err := groupMember.Start(); err != nil {
			os.Exit(97)
		}
	}

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
		if groupMember != nil {
			if err := groupMember.Wait(); err != nil {
				os.Exit(98)
			}
		}
		writePrivateFileForHelper(stopFile)
		_ = server.Shutdown(context.Background())
	}()
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		os.Exit(94)
	}
	os.Exit(0)
}

func TestGateGroupMemberHelper(t *testing.T) {
	if os.Getenv("GO_WANT_CLAUDEX_GROUP_MEMBER") != "1" {
		return
	}
	signals := make(chan os.Signal, 1)
	signalNotify(signals)
	ready := os.Getenv("CLAUDEX_GROUP_MEMBER_READY")
	stopped := os.Getenv("CLAUDEX_GROUP_MEMBER_STOPPED")
	_ = os.WriteFile(ready, []byte(strconv.Itoa(os.Getpid())), 0o600)
	<-signals
	writePrivateFileForHelper(stopped)
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
