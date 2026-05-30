package main

import (
	"embed"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

//go:embed scripts docker-compose.rag.yml docker-compose.cloudflared.yml VERSION LICENSE .env.example
var embedFS embed.FS

type CommandMapping struct {
	ScriptPath string
	ArgsPrefix []string
}

var commandMap = map[string]CommandMapping{
	"setup":          {ScriptPath: "scripts/setup.sh"},
	"start":          {ScriptPath: "scripts/agent-control.sh", ArgsPrefix: []string{"start"}},
	"stop":           {ScriptPath: "scripts/agent-control.sh", ArgsPrefix: []string{"stop"}},
	"restart":        {ScriptPath: "scripts/agent-control.sh", ArgsPrefix: []string{"restart"}},
	"status":         {ScriptPath: "scripts/agent-control.sh", ArgsPrefix: []string{"status"}},
	"logs":           {ScriptPath: "scripts/agent-control.sh", ArgsPrefix: []string{"logs"}},
	"shell":          {ScriptPath: "scripts/agent-control.sh", ArgsPrefix: []string{"shell"}},
	"open-dashboard": {ScriptPath: "scripts/agent-control.sh", ArgsPrefix: []string{"open-dashboard"}},
	"doctor":         {ScriptPath: "scripts/doctor.sh"},
	"clean":          {ScriptPath: "scripts/clean-all.sh"},
	"rag-up":         {ScriptPath: "scripts/rag-control.sh", ArgsPrefix: []string{"up"}},
	"rag-down":        {ScriptPath: "scripts/rag-control.sh", ArgsPrefix: []string{"down"}},
	"rag-status":      {ScriptPath: "scripts/rag-control.sh", ArgsPrefix: []string{"status"}},
	"rag-search":     {ScriptPath: "scripts/rag-search-bridge.sh"},
	"model-select":   {ScriptPath: "scripts/model-select.sh"},
	"sync-models":    {ScriptPath: "scripts/models-sync-omlx.sh"},
}

func printUsage(version string) {
	fmt.Printf(`omlx-agent - MLX Isolated Agent Stack CLI (v%s)

Usage:
  omlx-agent <command> [arguments]

Core Commands:
  setup           Run the interactive setup wizard to configure the environment
  start           Start the configured agent stack (Hermes or OpenClaw)
  stop            Stop the active agent stack
  restart         Restart the active agent stack
  status          Show status of active agent stack and ports
  logs            Show docker container logs for the active agent
  shell           Open an interactive shell inside the active agent container
  open-dashboard  Open the web dashboard / control UI for the active agent
  doctor          Run system checks and diagnostics
  clean           Remove all containers, configurations, and runtime cache

RAG Commands:
  rag-up          Start the RAG services (Qdrant, Tika, TEI)
  rag-down        Stop the RAG services
  rag-status      Show status of RAG services
  rag-search      Run a semantic query search on local RAG indexing

Model Commands:
  model-select    Interactively select and configure the active LLM model
  sync-models     Sync the local model catalog with LM Studio

Other Commands:
  version         Show the version of omlx-agent CLI
  help            Show this help information

Global variables can be overridden via environment variables or in ~/.omlx/.env.
`, version)
}

func main() {
	// Read embedded version
	versionBytes, err := embedFS.ReadFile("VERSION")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading embedded VERSION: %v\n", err)
		os.Exit(1)
	}
	version := strings.TrimSpace(string(versionBytes))

	// Find user home and set up ~/.omlx paths
	userHome, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error determining user home directory: %v\n", err)
		os.Exit(1)
	}

	omlxHome := filepath.Join(userHome, ".omlx")
	distDir := filepath.Join(omlxHome, "dist")

	// Ensure ~/.omlx structure exists
	if err := os.MkdirAll(omlxHome, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "Error creating directory %s: %v\n", omlxHome, err)
		os.Exit(1)
	}

	// Determine if extraction is needed
	needsExtract := false
	extractedVersionBytes, err := os.ReadFile(filepath.Join(distDir, "VERSION"))
	if err != nil {
		needsExtract = true
	} else {
		extractedVersion := strings.TrimSpace(string(extractedVersionBytes))
		if extractedVersion != version {
			needsExtract = true
		}
	}

	if needsExtract {
		fmt.Printf("Initializing/Updating oMLX Agent environment (v%s)...\n", version)
		// Clean existing dist directory
		_ = os.RemoveAll(distDir)
		if err := os.MkdirAll(distDir, 0755); err != nil {
			fmt.Fprintf(os.Stderr, "Error creating dist directory: %v\n", err)
			os.Exit(1)
		}

		// Extract embedded files
		err = fs.WalkDir(embedFS, ".", func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if path == "." {
				return nil
			}

			targetPath := filepath.Join(distDir, path)
			if d.IsDir() {
				return os.MkdirAll(targetPath, 0755)
			}

			data, err := embedFS.ReadFile(path)
			if err != nil {
				return err
			}

			var mode os.FileMode = 0644
			if strings.HasPrefix(path, "scripts/") || strings.HasSuffix(path, ".sh") || strings.HasSuffix(path, ".py") {
				mode = 0755
			}

			parent := filepath.Dir(targetPath)
			if err := os.MkdirAll(parent, 0755); err != nil {
				return err
			}

			return os.WriteFile(targetPath, data, mode)
		})

		if err != nil {
			fmt.Fprintf(os.Stderr, "Error extracting static assets: %v\n", err)
			os.Exit(1)
		}
	}

	// Parse arguments
	args := os.Args[1:]
	if len(args) == 0 {
		printUsage(version)
		os.Exit(0)
	}

	subCmd := args[0]
	if subCmd == "help" || subCmd == "-h" || subCmd == "--help" {
		printUsage(version)
		os.Exit(0)
	}

	if subCmd == "version" || subCmd == "-v" || subCmd == "--version" {
		fmt.Printf("omlx-agent version %s\n", version)
		os.Exit(0)
	}

	mapping, ok := commandMap[subCmd]
	if !ok {
		fmt.Fprintf(os.Stderr, "Unknown command: %s\nRun 'omlx-agent help' for usage.\n", subCmd)
		os.Exit(1)
	}

	// Prepare execution of the target script
	scriptPath := filepath.Join(distDir, mapping.ScriptPath)
	var combinedArgs []string
	combinedArgs = append(combinedArgs, mapping.ArgsPrefix...)
	combinedArgs = append(combinedArgs, args[1:]...)

	cmd := exec.Command("/bin/bash", append([]string{scriptPath}, combinedArgs...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	// Set environment variables, overriding OMLX_HOME
	cmd.Env = append(os.Environ(), "OMLX_HOME="+omlxHome, "OMLX_CLI=1")

	err = cmd.Run()
	if err != nil {
		if exitError, ok := err.(*exec.ExitError); ok {
			os.Exit(exitError.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "Command execution failed: %v\n", err)
		os.Exit(1)
	}
}
