# Guide: Connecting n8n Workflows to the AI Agent via MCP

This guide explains how to enable the self-hosted **n8n** automation server, build workflows, and expose them as tools that your local AI agent (Hermes) can invoke directly.

---

## 1. Enabling and Launching n8n

n8n is disabled by default to conserve system resources. To enable it:

1. Open your `.env` file in the project root.
2. Change `N8N_ENABLED` to `1`:
   ```env
   N8N_ENABLED='1'
   ```
3. Apply changes and start/restart the stack:
   ```bash
   make rag-down && make rag-up
   ```
   *(Or run the interactive wizard via `make setup` and select **Yes** when prompted for n8n workflow automation).*

Once launched, n8n runs in a Docker container named `mlx-n8n` and saves its database and settings into a named volume `rag-n8n-data`. The Web UI is accessible on the host at:
👉 **[http://127.0.0.1:5678](http://127.0.0.1:5678)**

---

## 2. Exposing n8n Workflows as MCP Tools

n8n includes a native **MCP Server Trigger** node that allows you to expose any custom workflow as an MCP tool.

### Step 1: Create a Workflow with the MCP Trigger
1. Open the n8n Web UI (`http://127.0.0.1:5678`) and click **Create Workflow**.
2. Add a first node and search for **MCP Server Trigger**.
3. Configure the trigger node:
   * **Path**: Set a unique URL slug (e.g. `send-telegram` or `jira-ticket`).
   * **Name**: The name of the tool as the AI agent will see it (e.g., `send_telegram_notification`). Use underscores and lowercase.
   * **Description**: Explain what the tool does (e.g. `Sends a text message to the user via Telegram`). **Be detailed** — the AI agent uses this description to decide when to call the tool.
   * **Arguments**: Define what input parameters the tool expects. For example, add a string parameter `message`.
4. Connect the rest of your automation nodes (e.g., a Telegram node, Notion node, or custom HTTP request node) and map the arguments from the trigger node (e.g., `{{ $json.message }}`).

### Step 2: Activate the Workflow
1. Toggle the **Production URL** option to **ON** inside the MCP Server Trigger node.
2. Toggle the workflow to **Active** (top-right corner).
3. Open the trigger node settings and copy the **Production URL** generated at the top (e.g., `http://localhost:5678/webhook/production/mcp/your-unique-path`).
   * *Note: If the agent is running in Docker, it should use the container-internal network alias: `http://host.docker.internal:5678/webhook/production/mcp/your-unique-path`.*

---

## 3. Registering the n8n tool in the Agent

To make your Hermes agent aware of your new n8n tool, you must register the n8n MCP endpoint in the agent's configuration.

1. Open your agent's MCP configuration file (typically in `.runtime/config/config.yaml` or similar, depending on your runtime settings).
2. Under the `mcpServers` block, add your n8n endpoint as an SSE (Server-Sent Events) or HTTP endpoint:
   ```yaml
   mcpServers:
     n8n-automation:
       url: "http://host.docker.internal:5678/webhook/production/mcp/your-unique-path"
       headers:
         # Include any authorization headers if configured in n8n
         Authorization: "Bearer your-optional-token"
   ```
3. Restart your agent container:
   ```bash
   make agent-restart
   ```
4. The agent will now see the new tool (e.g., `send_telegram_notification`) and invoke it automatically when relevant.
